import Testing
@testable import HunchCore

@Suite struct AutocorrectDemoTests {
    typealias Demo = AutocorrectDemo

    private func after(_ i: Int, _ s: Demo.Switches) -> String {
        Demo.text(Demo.script[i], s).after
    }

    @Test func allOnFixesEverythingButTheShorthand() {
        let s = Demo.Switches()
        #expect(after(0, s) == "I received your email, thx")
        #expect(after(1, s) == "Monday works, but we don\u{2019}t think they\u{2019}re ready tomorrow")
        #expect(after(2, s) == "can u send the address, the office is over there.")
    }

    @Test func shorthandIsCorrectedWhenNotAllowed() {
        let s = Demo.Switches(allowChatShorthand: false)
        #expect(after(0, s) == "I received your email, thanks")
        #expect(after(2, s).hasPrefix("can you send"))
    }

    @Test func eachSwitchGovernsOnlyItsOwnSlip() {
        let off: [(WritableKeyPath<Demo.Switches, Bool>, Demo.Slip)] = [
            (\.capitalization, .capital), (\.punctuation, .apostrophe), (\.confusedWords, .confused),
        ]
        for (path, slip) in off {
            var s = Demo.Switches()
            s[keyPath: path] = false
            for word in Demo.script.flatMap({ $0 }) {
                let resolved = Demo.resolve(word, s)
                #expect(resolved.changed == (word.fix != nil && word.slip != slip && word.slip != .shorthand))
            }
        }
    }

    @Test func misspellingsAreFixedWheneverAutocorrectIsOn() {
        let s = Demo.Switches(capitalization: false, punctuation: false, confusedWords: false)
        #expect(after(0, s) == "i received your email, thx")
        #expect(after(1, s) == "monday works, but we dont think their ready tomorrow")
    }

    @Test func suggestCorrectionsOffLeavesEverythingAsTyped() {
        let s = Demo.Switches(suggestCorrections: false, allowChatShorthand: false)
        for sentence in Demo.script {
            let text = Demo.text(sentence, s)
            #expect(text.before == text.after)
        }
    }

    @Test func theScriptShowsEveryKindOfSlip() {
        let kinds = Set(Demo.script.flatMap { $0 }.compactMap(\.slip))
        #expect(kinds == Set(Demo.Slip.allCases))
        #expect(Demo.script.flatMap { $0 }.allSatisfy { ($0.fix == nil) == ($0.slip == nil) })
    }

    @Test func confusedWordsLandOneWordLaterOthersRightAway() {
        for sentence in Demo.script {
            for (i, word) in sentence.enumerated() {
                let landing = Demo.landingIndex(of: i, in: sentence)
                if word.slip == .confused, i + 1 < sentence.count {
                    #expect(landing == i + 1)
                } else {
                    #expect(landing == i)
                }
            }
        }
        // "their ready" waits for "ready"; "over their." is last, so it lands at the sentence's end.
        #expect(Demo.landingIndex(of: 6, in: Demo.script[1]) == 7)
        #expect(Demo.landingIndex(of: 9, in: Demo.script[2]) == 9)
    }
}
