@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Records the default microphone as 16 kHz mono float samples, what whisper.cpp takes, and reports
/// a level for the pill. Nothing is written to disk.
final class MicRecorder: @unchecked Sendable {
    /// Longest recording kept (whisper handles more, but the cleanup prompt has a budget).
    static let maxSeconds: Double = 300

    private let engine = AVAudioEngine()
    private let samples = Mutex<[Float]>([])
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                       interleaved: false)!
    private var converter: AVAudioConverter?
    private(set) var isRecording = false

    enum Failure: Error { case noInput, engine(String) }

    static var permission: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts recording; `level` gets 0...1 about every 50 ms, on the main thread.
    func start(level: @escaping @MainActor @Sendable (Float) -> Void) throws {
        guard !isRecording else { return }
        samples.withLock { $0.removeAll(keepingCapacity: true) }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure.noInput }
        guard let converter = AVAudioConverter(from: format, to: target) else { throw Failure.noInput }
        self.converter = converter
        let target = self.target
        let cap = Int(Self.maxSeconds * target.sampleRate)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = target.sampleRate / format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            self.samples.withLock { all in
                if all.count < cap { all.append(contentsOf: chunk.prefix(cap - all.count)) }
            }
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(1, chunk.count)))
            // Speech sits around 0.02–0.2 RMS; spread that over the bars.
            let shown = min(1, max(0, (20 * log10(max(rms, 1e-5)) + 50) / 40))
            Task { @MainActor in level(shown) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw Failure.engine(error.localizedDescription)
        }
        isRecording = true
    }

    /// Stops and hands back everything recorded.
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        return samples.withLock { all in
            let out = all
            all.removeAll()
            return out
        }
    }
}
