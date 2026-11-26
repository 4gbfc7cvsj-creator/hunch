import HunchCore

/// Turns text into what the Unicode-event inserter posts: Unicode chunks and, for hosts that need
/// it, real Space key presses. Pure, so the host quirks are testable without posting events.
///
/// `nonBreakingSpaces` is applied first: every U+0020 becomes U+00A0, so with both flags on no
/// Space key is pressed. With no workarounds the result is exactly `TextChunker.chunks`.
public enum InsertionTextTransform {
    public enum Run: Sendable, Equatable {
        /// One keyboard event carrying these UTF-16 units.
        case unicode([UInt16])
        /// One press of a virtual key with no characters attached.
        case key(keyCode: UInt16)
    }

    /// kVK_Space; layout-independent, so no keyboard-layout mapping is needed.
    public static let spaceKeyCode: UInt16 = 49

    /// The runs to post, in order; each `.unicode` run is one `TextChunker` chunk.
    public static func runs(_ text: String, workarounds: InsertionWorkarounds,
                            chunkSize: Int = TextChunker.defaultChunkSize) -> [Run] {
        var text = text
        if workarounds.nonBreakingSpaces {
            text = String(String.UnicodeScalarView(text.unicodeScalars.map { $0 == " " ? "\u{00A0}" : $0 }))
        }
        guard workarounds.spaceAsKeyEvent else {
            return TextChunker.chunks(text, chunkSize: chunkSize).map(Run.unicode)
        }
        var result: [Run] = []
        var segment = ""
        func flush() {
            result += TextChunker.chunks(segment, chunkSize: chunkSize).map(Run.unicode)
            segment = ""
        }
        // Splits on whole " " clusters only; a space carrying a combining mark stays Unicode.
        for cluster in text {
            if cluster == " " {
                flush()
                result.append(.key(keyCode: spaceKeyCode))
            } else {
                segment.append(cluster)
            }
        }
        flush()
        return result
    }

    /// The text `runs` stand for (a Space press counts as " "), e.g. to paste what is left after
    /// posting failed part-way.
    public static func text<Runs: Sequence<Run>>(of runs: Runs) -> String {
        var units: [UInt16] = []
        for run in runs {
            switch run {
            case .unicode(let u): units += u
            case .key(let code): if code == spaceKeyCode { units.append(0x20) }
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
