import HunchCore
import Testing
@testable import HunchInput

// MARK: Chord matching

@Test func maskDropsCapsLockFnAndNumericPad() {
    let capsLock: UInt64 = 0x10000, fn: UInt64 = 0x800000, numPad: UInt64 = 0x200000
    #expect(ChordMatcher.mask(ChordMatcher.option | capsLock | fn | numPad) == ChordMatcher.option)
}

@Test func plainTabMatchesTabBindingDespiteCapsLock() {
    let event = ChordMatcher.chord(keyCode: 48, rawFlags: 0x10000 | 0x100) // caps lock + device bit
    #expect(ChordMatcher.matches(event, .tab))
}

@Test func modifiersMustMatchExactly() {
    let optionTab = ChordMatcher.chord(keyCode: 48, rawFlags: ChordMatcher.option)
    #expect(!ChordMatcher.matches(optionTab, .tab))
    #expect(ChordMatcher.matches(optionTab, .optionTab))
    #expect(!ChordMatcher.matches(ChordMatcher.chord(keyCode: 48, rawFlags: ChordMatcher.shift), .tab))
}

@Test func nilBindingNeverMatches() {
    #expect(!ChordMatcher.matches(.tab, nil))
}

@Test func optionShiftTabDoesNotMatchOptionTab() {
    #expect(!ChordMatcher.matches(.optionShiftTab, .optionTab))
    #expect(ChordMatcher.matches(.optionShiftTab, .optionShiftTab))
}

// MARK: Timebase and freshness

@Test func appleSiliconTimebaseConverts() {
    let tb = MachTimebase(numer: 125, denom: 3)
    #expect(tb.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
    #expect(tb.ticks(fromNanoseconds: 1_500_000_000) == 36_000_000)
}

@Test func identityTimebase() {
    let tb = MachTimebase(numer: 1, denom: 1)
    #expect(tb.ticks(fromNanoseconds: 42) == 42)
}

@Test func timebaseSaturatesInsteadOfTrapping() {
    let tb = MachTimebase(numer: 125, denom: 3)
    #expect(tb.nanoseconds(fromTicks: .max) == .max)
}

@Test func freshnessBoundaries() {
    #expect(Freshness.isFresh(publishedAt: 100, now: 200, maxAgeTicks: 100))
    #expect(!Freshness.isFresh(publishedAt: 100, now: 201, maxAgeTicks: 100))
    #expect(Freshness.isFresh(publishedAt: 300, now: 200, maxAgeTicks: 100)) // published after the read
}

// MARK: Chunking

private func decode(_ chunks: [[UInt16]]) -> String { String(decoding: chunks.joined(), as: UTF16.self) }

@Test func asciiChunksAtSize() {
    let chunks = TextChunker.chunks(String(repeating: "a", count: 40), chunkSize: 16)
    #expect(chunks.map(\.count) == [16, 16, 8])
}

@Test func emptyTextHasNoChunks() {
    #expect(TextChunker.chunks("").isEmpty)
}

@Test func surrogatePairsAreNotSplit() {
    // 15 ASCII + one astral emoji (2 units) must not produce a 16-unit chunk ending in a high surrogate.
    let text = String(repeating: "x", count: 15) + "😀" + "y"
    let chunks = TextChunker.chunks(text, chunkSize: 16)
    #expect(chunks.map(\.count) == [15, 3])
    #expect(decode(chunks) == text)
    for chunk in chunks { #expect(String(validating: chunk, as: UTF16.self) != nil) }
}

@Test func zwjFamilyEmojiStaysWhole() {
    let family = "👨‍👩‍👧‍👦" // 11 UTF-16 units, one grapheme
    let text = "abcdefgh" + family
    let chunks = TextChunker.chunks(text, chunkSize: 16)
    #expect(chunks.count == 2)
    #expect(String(decoding: chunks[1], as: UTF16.self) == family)
}

@Test func clusterLargerThanRequestedSizeGoesAlone() {
    let family = "👨‍👩‍👧‍👦"
    let chunks = TextChunker.chunks("a" + family + "b", chunkSize: 4)
    #expect(chunks.count == 3)
    #expect(String(decoding: chunks[1], as: UTF16.self) == family)
}

@Test func combiningMarksStayWithBase() {
    let text = String(repeating: "e\u{301}", count: 9) // 18 units, 9 clusters of 2
    let chunks = TextChunker.chunks(text, chunkSize: 5)
    #expect(chunks.allSatisfy { $0.count % 2 == 0 && $0.count <= 5 })
    #expect(decode(chunks) == text)
}

@Test func chineseTextRoundTrips() {
    let text = "我们明天下午三点在会议室讨论这个项目的进展情况吧"
    let chunks = TextChunker.chunks(text, chunkSize: 16)
    #expect(chunks.map(\.count) == [16, 8])
    #expect(decode(chunks) == text)
}

@Test func chunkSizeIsClampedToHardLimitAndAtLeastOne() {
    #expect(TextChunker.effectiveSize(0) == 1)
    #expect(TextChunker.effectiveSize(100) == TextChunker.hardLimit)
    #expect(TextChunker.chunks(String(repeating: "z", count: 50), chunkSize: 100).map(\.count) == [20, 20, 10])
}

@Test func oversizedClusterSplitsOnlyAtScalarBoundaries() {
    // One grapheme: base + 25 combining marks = 26 units > hard limit.
    let cluster = "a" + String(repeating: "\u{301}", count: 25)
    let chunks = TextChunker.chunks(cluster, chunkSize: 16)
    #expect(chunks.allSatisfy { $0.count <= TextChunker.hardLimit })
    #expect(decode(chunks) == cluster)
}

// MARK: Printable detection

@Test func lettersAndSpaceArePrintable() {
    #expect(PrintableDetector.isPrintable(utf16: Array("a".utf16), modifiers: 0))
    #expect(PrintableDetector.isPrintable(utf16: Array(" ".utf16), modifiers: ChordMatcher.shift))
    #expect(PrintableDetector.isPrintable(utf16: Array("中".utf16), modifiers: 0))
    #expect(PrintableDetector.isPrintable(utf16: Array("å".utf16), modifiers: ChordMatcher.option))
}

@Test func controlsAndFunctionKeysAreNotPrintable() {
    for unit: UInt16 in [0x09, 0x0D, 0x08, 0x1B, 0x7F, 0xF700, 0xF728] {
        #expect(!PrintableDetector.isPrintable(utf16: [unit], modifiers: 0))
    }
    #expect(!PrintableDetector.isPrintable(utf16: [], modifiers: 0))
}

@Test func commandAndControlChordsAreNotTyping() {
    #expect(!PrintableDetector.isPrintable(utf16: Array("c".utf16), modifiers: ChordMatcher.command))
    #expect(!PrintableDetector.isPrintable(utf16: Array("c".utf16), modifiers: ChordMatcher.control))
}

@Test func loneSurrogateIsNotPrintable() {
    #expect(!PrintableDetector.isPrintable(utf16: [0xD83D], modifiers: 0))
}
