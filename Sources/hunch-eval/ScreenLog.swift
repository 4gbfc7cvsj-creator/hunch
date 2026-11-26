import CoreGraphics
import Foundation
import HunchCore
import HunchScreen

/// `screen-log --log screen.log [--grep text] [--last N] [--bundle id] [--no-sides] [--dump]`: replays OCR reads
/// the app logged (`ocr lines window=… field=… caret=…` blocks in screen.log, Diagnostics debug logging) through
/// the app's screen pipeline, printing the screen text as the model would get it. `--grep` keeps reads with a
/// line containing the text; `--last` keeps the newest N (default 1). `--bundle` sets the app for chat sides
/// (default Messages); `--dump` also prints the raw lines with their rects. For a list chat
/// (`--bundle com.hnc.Discord`) the log holds no images, so no avatars: `--me-name` stands in for a
/// learned avatar with that header name ("" for a name OCR never reads), so groups under other
/// readable names are labeled Them.
func runScreenLogCommand(_ args: [String]) -> Int32 {
    let parsed = ParsedArgs(args, valueOptions: ["--log", "--grep", "--last", "--bundle", "--me-name"])
    guard let path = parsed.value("--log"), let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else {
        printErr("usage: hunch-eval screen-log --log <screen.log> [--grep text] [--last N] [--bundle id] [--no-sides] [--dump]")
        return ExitCode.usage
    }
    let bundle = parsed.value("--bundle") ?? "com.apple.MobileSMS"
    let sides = !parsed.flags.contains("--no-sides")
    let reads = ScreenLogRead.parse(text).filter { read in
        parsed.value("--grep").map { g in read.lines.contains { $0.text.contains(g) } } ?? true
    }
    for read in reads.suffix(Int(parsed.value("--last") ?? "1") ?? 1) {
        print("== \(read.stamp) field=\(read.field.map { "\($0)" } ?? "-")")
        if parsed.flags.contains("--dump") {
            for l in read.lines { print("   \(Int(l.rect.minX)),\(Int(l.rect.minY)),\(Int(l.rect.width))x\(Int(l.rect.height)) \(l.text)") }
            print("--")
        }
        let mine = parsed.value("--me-name").map {
            [MyAvatar(print: AvatarPrint(cells: []), names: [ChatSides.readName($0)])]
        } ?? []
        print(read.pipelineText(bundleID: bundle, sides: sides, mine: mine) ?? "(none)")
        print("")
    }
    return 0
}

/// One logged OCR read: the field, caret and lines (screen points, top-left origin).
struct ScreenLogRead {
    var stamp: String
    var field: CGRect?
    var caret: CGRect
    var lines: [OCRLine]

    /// The read through the app's pipeline, as `ScreenContextProvider` runs it (no typed text).
    func pipelineText(bundleID: String, sides: Bool, sent: [String] = [], mine: [MyAvatar] = []) -> String? {
        ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: caret.midX, y: caret.midY), field: field,
                                   maxCharacters: 16000, chatSides: sides,
                                   bubbleApp: ChatSides.isBubbleApp(bundleID: bundleID), sentMessages: sent,
                                   senderNames: ChatSides.hasSenderNames(surface: .chat, bundleID: bundleID),
                                   listChat: ChatSides.isListChat(bundleID: bundleID), myAvatars: mine)?.text
    }

    static func rect(_ s: Substring) -> CGRect? {
        let parts = s.split(separator: ",")
        guard parts.count == 3, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        let wh = parts[2].split(separator: "x")
        guard wh.count == 2, let w = Double(wh[0]), let h = Double(wh[1]) else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func parse(_ log: String) -> [ScreenLogRead] {
        var reads: [ScreenLogRead] = []
        var current: ScreenLogRead?
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.first?.isNumber == true, raw.count > 20, raw.dropFirst(4).first == "-", raw.contains("Z ") {
                // A timestamped note ends the current read.
                if let c = current { reads.append(c) }
                current = nil
                guard let r = raw.range(of: " ocr lines ") else { continue }
                var field: CGRect?, caret = CGRect.zero
                for token in raw[r.upperBound...].split(separator: " ") {
                    if token.hasPrefix("field=") { field = rect(token.dropFirst(6)) }
                    if token.hasPrefix("caret=") { caret = rect(token.dropFirst(6)) ?? .zero }
                }
                current = ScreenLogRead(stamp: String(raw.prefix(20)), field: field, caret: caret, lines: [])
                continue
            }
            guard current != nil else { continue }
            let parts = raw.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let r = rect(parts[0]), let conf = Float(parts[1]) else { continue }
            current?.lines.append(OCRLine(text: String(parts[2]), confidence: conf, rect: r))
        }
        if let c = current { reads.append(c) }
        return reads
    }
}
