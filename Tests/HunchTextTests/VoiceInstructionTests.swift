// Voice instructions for Write for me (experimental): routing, transcript trimming, the edit-and-rerun
// bookkeeping, shortcut clashes, and the empty range a spoken description writes into.
import HunchCore
import Testing
@testable import HunchText

@Suite struct VoiceInstructionRouteTests {
    private func press(featureOn: Bool = true, dictationEnabled: Bool = true, panelOpen: Bool = false,
                       writeBusy: Bool = false, speechBusy: Bool = false, secureInput: Bool = false,
                       readableField: Bool = true) -> Result<VoiceInstructionTarget, VoiceInstructionRefusal> {
        VoiceInstructionRoute.atPress(.init(featureOn: featureOn, dictationEnabled: dictationEnabled,
                                            panelOpen: panelOpen, writeBusy: writeBusy, speechBusy: speechBusy,
                                            secureInput: secureInput, readableField: readableField))
    }

    @Test func fieldWhenNothingElseIsGoingOn() {
        #expect(press() == .success(.field))
    }

    @Test func panelOpenRoutesToRefine() {
        #expect(press(panelOpen: true) == .success(.panel))
        // The panel is Hunch's own window: the host field's state doesn't matter.
        #expect(press(panelOpen: true, secureInput: true, readableField: false) == .success(.panel))
    }

    @Test func offWhenToggleOrDictationIsOff() {
        #expect(press(featureOn: false) == .failure(.off))
        #expect(press(dictationEnabled: false) == .failure(.off))
        #expect(press(featureOn: false, panelOpen: true) == .failure(.off))
    }

    @Test func busyWhileDictationOrWriteForMeIsInFlight() {
        // A dictation recording or being cleaned up: no second recording, no overlapping insert.
        #expect(press(speechBusy: true) == .failure(.busy))
        #expect(press(panelOpen: true, speechBusy: true) == .failure(.busy))
        // Write for me reading the field to open, or inserting an accepted draft.
        #expect(press(writeBusy: true) == .failure(.busy))
    }

    @Test func secureFieldsRefuse() {
        #expect(press(secureInput: true) == .failure(.secureField))
        #expect(press(secureInput: true, readableField: false) == .failure(.secureField))
    }

    @Test func unreadableFieldRefuses() {
        // Hunch off in this app (per-app toggle), or nothing editable focused: Write for me
        // can't work here, so neither can its voice version.
        #expect(press(readableField: false) == .failure(.noField))
    }

    @Test func modelStateIsNotPartOfTheDecision() {
        // An idle-released model routes like a loaded one: the draft request loads it (no second press).
        // PressState has no model field at all; the same state always gives the same answer.
        #expect(press() == press())
    }

    @Test func deliveryWithSelectionTransformsIt() {
        let d = VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: false, writeBusyNow: false,
                                                 selectedText: "We will ship the update on Friday.")
        #expect(d == .transformSelection)
        let zh = VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: false, writeBusyNow: false,
                                                  selectedText: "我們星期五會發佈更新。")
        #expect(zh == .transformSelection)
    }

    @Test func deliveryWithoutSelectionWritesAtCaret() {
        for selected in [nil, "", "  \n "] as [String?] {
            #expect(VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: false, writeBusyNow: false,
                                                     selectedText: selected) == .writeAtCaret)
        }
    }

    @Test func deliveryRefusesTooLongSelection() {
        let long = String(repeating: "a", count: WriteRange.maxCharacters + 1)
        #expect(VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: false, writeBusyNow: false,
                                                 selectedText: long) == .refuse(.selectionTooLong))
    }

    @Test func deliveryToPanel() {
        #expect(VoiceInstructionRoute.atDelivery(target: .panel, panelOpenNow: true, writeBusyNow: false,
                                                 selectedText: nil) == .refine)
        // Esc closed the panel while the words were being transcribed: nothing opens, nothing is typed.
        #expect(VoiceInstructionRoute.atDelivery(target: .panel, panelOpenNow: false, writeBusyNow: false,
                                                 selectedText: nil) == .refuse(.panelClosed))
    }

    @Test func deliveryForFieldAfterPanelOpenedOrInsertStarted() {
        // The typed Write for me shortcut opened the panel while the words were being transcribed.
        #expect(VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: true, writeBusyNow: false,
                                                 selectedText: "x") == .refuse(.panelOpened))
        #expect(VoiceInstructionRoute.atDelivery(target: .field, panelOpenNow: false, writeBusyNow: true,
                                                 selectedText: "x") == .refuse(.busy))
    }
}

@Suite struct VoiceInstructionTextTests {
    @Test func trimsLightly() {
        #expect(VoiceInstruction.clean("  Make this shorter.  ") == "Make this shorter")
        #expect(VoiceInstruction.clean("make it\n  more   polite") == "make it more polite")
        #expect(VoiceInstruction.clean("\u{201C}Turn this into bullet points.\u{201D}") == "Turn this into bullet points")
        #expect(VoiceInstruction.clean("Translate to Chinese?") == "Translate to Chinese?")
        #expect(VoiceInstruction.clean("Wait...") == "Wait...")
    }

    @Test func keepsChineseInstructions() {
        #expect(VoiceInstruction.clean("把這段改得比較正式。") == "把這段改得比較正式")
        #expect(VoiceInstruction.clean("「翻譯成英文」") == "翻譯成英文")
        #expect(VoiceInstruction.clean("跟他說好，但是下週比較方便") == "跟他說好，但是下週比較方便")
    }

    @Test func nothingHeard() {
        // The pill says "Didn't catch that" and nothing opens.
        for raw in ["", "   ", ".", "um", "Um. Uh.", "嗯", "\u{201C}\u{201D}"] {
            #expect(VoiceInstruction.clean(raw) == nil, "\(raw)")
        }
    }

    @Test func heardFitsThePill() {
        #expect(VoiceInstruction.heard("shorter") == "\u{201C}shorter\u{201D}")
        let long = VoiceInstruction.heard(String(repeating: "x", count: 100), limit: 20)
        #expect(long.count == 22)
        #expect(long.contains("…"))
    }

    @Test func everyRefusalHasAMessage() {
        let all: [VoiceInstructionRefusal] = [.off, .busy, .secureField, .noField, .panelClosed, .panelOpened,
                                             .selectionTooLong]
        for r in all { #expect(!VoiceInstruction.message(r).isEmpty) }
        #expect(VoiceInstruction.message(.secureField).contains("password"))
    }

    @Test func separatorBeforeADraftAtTheCaret() {
        #expect(VoiceInstruction.separator(before: "", draft: "Hi") == "")
        #expect(VoiceInstruction.separator(before: "Thanks!", draft: "See you") == " ")
        #expect(VoiceInstruction.separator(before: "Thanks! ", draft: "See you") == "")
        #expect(VoiceInstruction.separator(before: "Hi Alex,\n", draft: "Yes") == "")
        #expect(VoiceInstruction.separator(before: "好的", draft: "下週見") == "")
        #expect(VoiceInstruction.separator(before: "OK", draft: "下週見") == "")
        #expect(VoiceInstruction.separator(before: "OK", draft: ", then") == "")
    }

    @Test func shortcutClashes() {
        let bindings = AcceptBindings()
        let dictation = DictationSettings.defaultShortcut
        #expect(VoiceInstruction.conflict(VoiceInstructionSettings.defaultShortcut, dictation: dictation,
                                          bindings: bindings) == nil)
        #expect(VoiceInstruction.conflict(dictation, dictation: dictation, bindings: bindings) == "Dictation")
        #expect(VoiceInstruction.conflict(.optionShiftTab, dictation: dictation, bindings: bindings) == "Write for me")
        #expect(VoiceInstruction.conflict(nil, dictation: dictation, bindings: bindings) == nil)
    }
}

@Suite struct SpokenInstructionTests {
    @Test func editingTheFirstInstructionStartsOver() {
        let s = SpokenInstruction(text: "make this shorter", kind: .initial)
        #expect(s.rerun(with: "make this shorter and friendlier")
                == .init(instruction: "make this shorter and friendlier", refinements: [], previousDraft: nil))
        #expect(s.rerun(with: "   ") == nil)
    }

    @Test func editingASpokenRefinementReplacesIt() {
        let s = SpokenInstruction(text: "less formal",
                                  kind: .refinement(baseRefinements: ["shorter"], baseDraft: "Draft two"))
        #expect(s.rerun(with: "much less formal")
                == .init(instruction: nil, refinements: ["shorter", "much less formal"], previousDraft: "Draft two"))
    }
}

@Suite struct WriteRangeAtCaretTests {
    @Test func replacesNothing() {
        let r = WriteRange.atCaret(before: "Hi Alex,\n\n", after: "\n\nBest, Sam")
        #expect(r.isAtCaret)
        #expect(r.deleteBackward == 0 && r.deleteForward == 0 && !r.replacesSelection)
        #expect(r.insertion(for: "  Yes, but next week works better.\n") == "Yes, but next week works better.")
    }

    @Test func spaceAfterAWord() {
        let r = WriteRange.atCaret(before: "Sounds good.", after: "")
        #expect(r.insertion(for: "See you Friday.") == " See you Friday.")
        #expect(WriteRange.atCaret(before: "好的。", after: "").insertion(for: "下週見") == "下週見")
    }

    @Test func stillHoldsOnlyWhereTheCaretWas() {
        let r = WriteRange.atCaret(before: "Hi Alex,\n\n", after: "Best")
        #expect(r.stillHolds(before: "Hi Alex,\n\n", after: "Best", selected: "", selectionLength: 0, markedText: false))
        // The user typed meanwhile or moved the caret: the draft goes on the clipboard instead.
        #expect(!r.stillHolds(before: "Hi Alex,\n\nok", after: "Best", selected: "", selectionLength: 0,
                              markedText: false))
        #expect(!r.stillHolds(before: "Hi Alex,\n\n", after: "Best", selected: "Best", selectionLength: 4,
                              markedText: false))
        #expect(!r.stillHolds(before: "Hi Alex,\n\n", after: "Best", selected: "", selectionLength: 0, markedText: true))
    }

    @Test func selectionRangesAreUnchanged() {
        let r = WriteRange(source: "Draft text", deleteBackward: 0, deleteForward: 0, replacesSelection: true,
                           textBefore: "", textAfter: "")
        #expect(!r.isAtCaret)
        #expect(r.insertion(for: "New text") == "New text")
    }
}

@Suite struct VoiceInstructionScriptTests {
    @Test func traditionalTextGetsTraditionalDraft() {
        let out = VoiceInstruction.matchScript("请准时到，也麻烦提前看看附件里的资料。", source: "敬請準時出席，並請事先閱讀附件中的資料。",
                                               prefersTraditional: false)
        #expect(!HanScript.usesSimplified(out))
        #expect(out.contains("請準時"))
    }

    @Test func englishTextFollowsTheUsersScript() {
        let draft = "会议改到周三下午3点。"
        #expect(HanScript.usesTraditional(VoiceInstruction.matchScript(draft, source: "The meeting moved.",
                                                                       prefersTraditional: true)))
        #expect(VoiceInstruction.matchScript(draft, source: "The meeting moved.", prefersTraditional: false) == draft)
    }

    @Test func simplifiedTextStaysSimplified() {
        let draft = "会议改到周三。"
        #expect(VoiceInstruction.matchScript(draft, source: "会议在周二。", prefersTraditional: true) == draft)
        #expect(VoiceInstruction.matchScript("Hello", source: "會議", prefersTraditional: true) == "Hello")
    }
}
