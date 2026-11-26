import HunchCore
import Testing
@testable import HunchPrompt

@Suite struct PlaceTests {
    private func text(_ framer: any PromptFramer, _ input: PromptInput, budget: Int = 4096,
                      profile: ModelProfile = unknownBase, counter: any TokenCounting = ScalarCounter()) -> String {
        framer.frame(input, profile: profile, budget: budget, counter: counter).segments.map(\.text).joined()
    }

    @Test func descriptionCombinations() {
        #expect(placeDescription(appName: nil, domain: nil, windowTitle: nil) == nil)
        #expect(placeDescription(appName: "  ", domain: "", windowTitle: "\n") == nil)
        #expect(placeDescription(appName: "Discord", domain: nil, windowTitle: nil) == "Discord")
        #expect(placeDescription(appName: nil, domain: "mail.google.com", windowTitle: nil) == "mail.google.com")
        #expect(placeDescription(appName: nil, domain: nil, windowTitle: "Inbox") == "window “Inbox”")
        #expect(placeDescription(appName: "Safari", domain: "mail.google.com", windowTitle: nil)
            == "Safari (mail.google.com)")
        #expect(placeDescription(appName: " Slack ", domain: nil, windowTitle: "  #dev   team ")
            == "Slack, window “#dev team”")
        #expect(placeDescription(appName: "Safari", domain: "a.com", windowTitle: "Hi") == "Safari (a.com), window “Hi”")
    }

    @Test func redundancyRules() {
        #expect(placeDescription(appName: "Discord", domain: "discord.com", windowTitle: nil) == "Discord")
        #expect(placeDescription(appName: "Notion", domain: "www.notion.so", windowTitle: nil) == "Notion")
        #expect(placeDescription(appName: "Notes", domain: nil, windowTitle: "notes") == "Notes")
        #expect(placeDescription(appName: "Notes", domain: nil, windowTitle: "Notes ") == "Notes")
        #expect(placeDescription(appName: nil, domain: nil, windowTitle: "***") == nil)
    }

    @Test func longTitleIsCappedAtWordBoundary() {
        let title = Array(repeating: "wordy", count: 40).joined(separator: " ")
        let place = try! #require(placeDescription(appName: "Notes", domain: nil, windowTitle: title))
        let inner = place.dropFirst("Notes, window “".count).dropLast(2)   // closing quote and ellipsis
        #expect(inner.count <= placeTitleLimit)
        #expect(inner.split(separator: " ").allSatisfy { $0 == "wordy" })
        #expect(place.hasSuffix("…”"))
    }

    @Test func blockPresentOnlyWithData() {
        for framer in [DocumentFramer(), DocumentFramer(.v2)] {
            let none = text(framer, PromptInput(before: "Hello there", surface: .chat))
            #expect(!none.contains("written") || !none.contains("Where"))
            let w = framer.wording
            #expect(!none.contains(w.place))
            let some = text(framer, PromptInput(before: "Hello there", surface: .chat, appName: "Discord",
                                                domain: "discord.com", windowTitle: "#general"))
            #expect(some.contains(w.place + "Discord, window “#general”\n"))
        }
        for w in [ChatPrefillFramer.Wording.v1, .v2] {
            let framer = ChatPrefillFramer(w)
            let none = text(framer, PromptInput(before: "Hello there"), profile: gemmaInstruct)
            #expect(!none.contains(w.placePrefix))
            let some = text(framer, PromptInput(before: "Hello there", appName: "Claude"), profile: gemmaInstruct)
            #expect(some.contains(w.placePrefix + "Claude" + w.placeSuffix))
        }
    }

    @Test func orderingAndCaretEnd() {
        let input = PromptInput(before: "works fine here in ", after: "ok", surface: .chat, globalInstructions: "Casual.",
                                appInstructions: "Short.", screenContext: "Screen words", clipboard: "Clip words",
                                appName: "Claude")
        for framer in [DocumentFramer(), DocumentFramer(.v2)] {
            let t = text(framer, input)
            let w = framer.wording
            let r = { (s: String) in t.range(of: s)!.lowerBound }
            #expect(r(w.surface) < r(w.place))
            #expect(r(w.place) < r(w.appNotes))
            #expect(t.hasSuffix("\n\nworks fine here in"))
        }
        for w in [ChatPrefillFramer.Wording.v1, .v2] {
            let prompt = ChatPrefillFramer(w).frame(input, profile: gemmaInstruct, budget: 4096, counter: ScalarCounter())
            #expect(prompt.segments.last?.text == "works fine here in")
            let t = prompt.segments.map(\.text).joined()
            #expect(t.range(of: w.placePrefix)!.lowerBound < t.range(of: w.appNotes)!.lowerBound)
        }
    }

    @Test func budgetPriorityKeepsPlaceBeforeScreenAndClipboardButAfterWriterNotes() {
        let screen = String(repeating: "screen ", count: 60)
        let input = PromptInput(before: "works fine here in ", globalInstructions: "Writer note text.",
                                screenContext: screen, clipboard: String(repeating: "clip ", count: 60), appName: "Claude")
        let framer = DocumentFramer()
        let w = framer.wording
        // Room for header + notes + place but nothing optional beyond.
        let fixed = (w.header + "\n" + w.writerNotes + "Writer note text.\n" + w.place + "Claude\n\n").count
        let budget = fixed + "works fine here in".count + 10
        let t = text(framer, input, budget: budget)
        #expect(t.contains(w.place + "Claude"))
        #expect(t.contains("Writer note text."))
        #expect(!t.contains("screen screen"))
        #expect(!t.contains("clip clip"))
        // Too tight for the place block: writer notes win.
        let tight = (w.header + "\n" + w.writerNotes + "Writer note text.\n\n").count + "works fine here in".count + 2
        let t2 = text(framer, input, budget: tight)
        #expect(t2.contains("Writer note text."))
        #expect(!t2.contains(w.place))
        #expect(t2.hasSuffix("works fine here in"))
    }

    @Test func noAssistantVocabularyInDocumentPlaceBlock() {
        let input = PromptInput(before: "See you", appName: "Mail", domain: "example.org", windowTitle: "Draft")
        for framer in [DocumentFramer(), DocumentFramer(.v2)] {
            let t = text(framer, input).lowercased()
            let words = t.split(whereSeparator: { !$0.isLetter && $0 != "." })
            for banned in ["ai", "bot", "llm"] { #expect(!words.contains(Substring(banned))) }
            for banned in ["assistant", "model", "autocomplete", "complet", "suggest", "predict", "generate"] {
                #expect(!t.contains(banned))
            }
        }
    }

    @Test func prefacePhrasesIncludePlaceLabels() {
        let phrases = DocumentFramer.prefacePhrases
        #expect(phrases.contains("Place of writing"))
        #expect(phrases.contains("Where this piece was typed"))
    }

    @Test func shortCJKStillGetsPlace() {
        let t = text(DocumentFramer(), PromptInput(before: "你好", appName: "WeChat"))
        #expect(!t.hasPrefix(DocumentFramer.header))
        #expect(t.contains("WeChat"))
        #expect(t.hasSuffix("你好"))
    }
}

@Suite struct WriterNameTests {
    private func text(_ framer: any PromptFramer, _ input: PromptInput) -> String {
        framer.frame(input, profile: unknownBase, budget: 4096, counter: ScalarCounter()).segments.map(\.text).joined()
    }

    @Test func nameAppearsInBothFramersOnlyWhenGiven() {
        let with = PromptInput(before: "Thanks for the update. Best,", aboutWriter: "Name: Alex Morgan.")
        let without = PromptInput(before: "Thanks for the update. Best,")
        for framer in [DocumentFramer() as any PromptFramer, ChatPrefillFramer()] {
            #expect(text(framer, with).contains("Name: Alex Morgan."))
            #expect(!text(framer, without).contains("Name:"))
        }
    }
}

@Test func fieldLabelInPlace() {
    #expect(placeDescription(appName: "Mail", domain: nil, windowTitle: nil, field: "Subject") == "Mail, field “Subject”")
    #expect(placeDescription(appName: "Discord", domain: "discord.com", windowTitle: "#general", field: "Message #general")
        == "Discord, window “#general”, field “Message #general”")
    // Repeats of the app name or window title add nothing.
    #expect(placeDescription(appName: "Notes", domain: nil, windowTitle: nil, field: "notes") == "Notes")
    #expect(placeDescription(appName: "Slack", domain: nil, windowTitle: "#dev", field: " #dev ") == "Slack, window “#dev”")
    #expect(placeDescription(appName: nil, domain: nil, windowTitle: nil, field: "Search") == "field “Search”")
    let long = Array(repeating: "label", count: 40).joined(separator: " ")
    #expect(placeDescription(appName: "X", domain: nil, windowTitle: nil, field: long)?.contains("…”") == true)
}

@Test func whoComesBeforeHow() {
    let input = PromptInput(before: "Thanks for the update. Best,", globalInstructions: "Casual and concise.",
                            aboutWriter: "Name: Alex Morgan. Product designer.")
    for framer in [DocumentFramer() as any PromptFramer, ChatPrefillFramer()] {
        let text = framer.frame(input, profile: unknownBase, budget: 4096, counter: ScalarCounter())
            .segments.map(\.text).joined()
        let who = text.range(of: "Name: Alex Morgan. Product designer.")
        let how = text.range(of: "Casual and concise.")
        #expect(who != nil && how != nil)
        if let who, let how { #expect(who.lowerBound < how.lowerBound) }
    }
}
