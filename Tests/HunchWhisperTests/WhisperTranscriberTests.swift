import AVFoundation
import Foundation
import Testing
@testable import HunchWhisper

/// Integration test: runs only with `HUNCH_WHISPER_MODEL` (a ggml model file) and
/// `HUNCH_WHISPER_AUDIO` (a folder with en.wav and zh.wav, 16 kHz mono) set.
@Suite struct WhisperTranscriberTests {
    private static let env = ProcessInfo.processInfo.environment

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test(.enabled(if: env["HUNCH_WHISPER_MODEL"] != nil && env["HUNCH_WHISPER_AUDIO"] != nil))
    func transcribesEnglishAndChinese() async throws {
        let model = URL(fileURLWithPath: Self.env["HUNCH_WHISPER_MODEL"]!)
        let audio = URL(fileURLWithPath: Self.env["HUNCH_WHISPER_AUDIO"]!)
        let whisper = WhisperTranscriber()
        let clock = ContinuousClock()
        var en: Transcript?
        let enTime = try await clock.measure {
            en = try await whisper.transcribe(samples(audio.appendingPathComponent("en.wav")), model: model,
                                              prompt: "Hunch.")
        }
        print("en (\(enTime)): \(en!.language ?? "?") \(en!.text)")
        #expect(en?.language == "en")
        #expect(en?.text.lowercased().contains("friday") == true)
        var zh: Transcript?
        let zhTime = try await clock.measure {
            zh = try await whisper.transcribe(samples(audio.appendingPathComponent("zh.wav")), model: model,
                                              prompt: "以下是繁體中文的句子。")
        }
        print("zh (\(zhTime)): \(zh!.language ?? "?") \(zh!.text)")
        #expect(zh?.language == "zh")
        #expect(zh?.text.contains("開會") == true || zh?.text.contains("开会") == true)
    }
}
