import Testing
@testable import HunchText

@Suite struct StreamWordsTests {
    @Test func latinWordsFinishAtWhitespace() {
        #expect(StreamWords.complete("") == "")
        #expect(StreamWords.complete(" wor") == "")
        #expect(StreamWords.complete(" world") == "")
        #expect(StreamWords.complete(" world ") == " world")
        #expect(StreamWords.complete(" world, how ar") == " world, how")
        #expect(StreamWords.complete("ing the") == "ing")
    }

    @Test func ideographsFinishAtOnce() {
        #expect(StreamWords.complete("一起") == "一起")
        #expect(StreamWords.complete("一起去吃飯吧！") == "一起去吃飯吧！")
        #expect(StreamWords.complete("我們去 Tai") == "我們去")
        #expect(StreamWords.complete("ですね") == "ですね")
    }
}

@Suite struct StreamWordsFilterTests {
    @Test func filterNeverHidesANewWord() {
        let pieces = ["", " he", "llo", " ", "wor", "ld", ", ", "一", "起", "去 ", "ab", "\n", "x"]
        var text = ""
        for piece in pieces {
            let next = text + piece
            if !StreamWords.mayHaveNewWord(next, after: text) {
                #expect(StreamWords.complete(next) == StreamWords.complete(text), "\(text) + \(piece)")
            }
            text = next
        }
    }

    @Test func filterSkipsGrowthInsideAWord() {
        #expect(!StreamWords.mayHaveNewWord(" hello wor", after: " hello w"))
        #expect(StreamWords.mayHaveNewWord(" hello world ", after: " hello world"))
        #expect(StreamWords.mayHaveNewWord("一起", after: "一"))
        #expect(StreamWords.mayHaveNewWord("abc", after: "xyz"))   // not an extension: in doubt
    }
}
