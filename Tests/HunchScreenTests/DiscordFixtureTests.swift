import CoreGraphics
import Foundation
import HunchCore
import ImageIO
import Testing
import Vision
@testable import HunchScreen

// Real Discord screenshots with their expected labels, kept only locally in
// `eval/local/discord-avatars/` (never committed: they show real people). The suite skips when the
// folder isn't there. Each screenshot runs through Vision OCR and the app's pipeline in image-pixel
// space; `cases.json` says which shot teaches the writer's avatar (a sent message) and which lines
// each shot must then show.

private let fixtureDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("eval/local/discord-avatars")

private struct FixtureCases: Decodable {
    struct Learn: Decodable { var shot: String; var sent: [String]; var me: [String]; var them: [String] }
    struct Case: Decodable {
        var shot: String
        /// Line prefixes that must appear.
        var me: [String]?
        var them: [String]?
        /// When set, the only "Me:" lines allowed (by prefix).
        var onlyMe: [String]?
    }
    var learn: Learn
    var cases: [Case]
    /// A shot that, with nothing learned, must stay unlabeled.
    var unknown: String

    static func load() -> FixtureCases? {
        guard let data = try? Data(contentsOf: fixtureDir.appendingPathComponent("cases.json")) else { return nil }
        return try? JSONDecoder().decode(FixtureCases.self, from: data)
    }
}

private struct Shot {
    var lines: [OCRLine]
    var image: CGImage
    var field: CGRect

    static func load(_ name: String) async throws -> Shot? {
        let url = fixtureDir.appendingPathComponent(name)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"].map { Locale.Language(identifier: $0) }
        let band = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let lines = try await request.perform(on: image).compactMap { obs -> OCRLine? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return OCRLine(text: top.string, confidence: top.confidence,
                           rect: CaptureGeometry.screenRect(normalized: obs.boundingBox.cgRect, in: band))
        }
        // The message box: the "Message #channel" placeholder's row, across to the window's right.
        guard let box = lines.first(where: { $0.text.hasPrefix("Message #") }) else { return nil }
        let field = CGRect(x: box.rect.minX - 90, y: box.rect.minY - 20,
                           width: CGFloat(image.width) - box.rect.minX + 70, height: box.rect.height + 40)
        return Shot(lines: lines, image: image, field: field)
    }

    func run(sent: [String] = [], mine: [MyAvatar] = []) -> ScreenPipelineResult? {
        let source = ImageAvatarSource(image: image, band: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let out = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: field.minX + 10, y: field.midY), field: field,
                                             maxCharacters: 16_000, chatSides: true, sentMessages: sent,
                                             listChat: true, myAvatars: mine,
                                             avatarAt: { source.print(in: $0, minSide: $1, maxSide: $2) })
        if ProcessInfo.processInfo.environment["GT_FIXTURE_DUMP"] != nil { print("== \(sent.isEmpty ? "" : "learn ")\(out?.text ?? "(none)")\n") }
        return out
    }
}

private let cases = FixtureCases.load()

@Suite(.enabled(if: cases != nil))
struct DiscordFixtureTests {
    private func lines(_ out: ScreenPipelineResult?) -> [String] {
        (out?.text ?? "").split(separator: "\n").map(String.init)
    }

    private func check(_ text: [String], has prefixes: [String]) {
        for p in prefixes { #expect(text.contains { $0.hasPrefix(p) }, "missing \(p)") }
    }

    private func learn() async throws -> [MyAvatar] {
        let c = try #require(cases).learn
        let shot = try #require(try await Shot.load(c.shot))
        let out = try #require(shot.run(sent: c.sent))
        #expect(out.learnedAvatars.count == 1)
        check(lines(out), has: c.me + c.them)
        return out.learnedAvatars
    }

    @Test func sentMessageTeachesTheAvatar() async throws {
        _ = try await learn()
    }

    @Test func learnedAvatarLabelsOtherScreens() async throws {
        let mine = try await learn()
        for c in try #require(cases).cases {
            let shot = try #require(try await Shot.load(c.shot))
            let text = lines(shot.run(mine: mine))
            check(text, has: (c.me ?? []) + (c.them ?? []))
            if let only = c.onlyMe {
                let extra = text.filter { $0.hasPrefix("Me:") && !only.contains(where: $0.hasPrefix) }
                #expect(extra.isEmpty, "\(c.shot): unexpected \(extra)")
            }
        }
    }

    @Test func nothingKnownLeavesTheScreenUnlabeled() async throws {
        let unknown = try #require(cases).unknown
        let shot = try #require(try await Shot.load(unknown))
        let text = lines(shot.run())
        #expect(!text.contains { $0.hasPrefix("Me:") || $0.hasPrefix("Them:") })
    }
}
