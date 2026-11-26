import Foundation
import HunchCore

/// The suggested-replies prompt: one user turn on an instruct model with the task, the writer, the
/// place and the screen text, then an open model turn. The answer is a short list, one reply per
/// line (`SuggestedReplies.parse`), or `ReplyRequest.noneMarker` when nothing on screen asks for a
/// reply. Base models get no replies (the app never asks one); a base profile still gets this
/// prompt as plain text so the call cannot fail.
extension WriteForMeFramer {
    public static let repliesFrameID = "suggested-replies-v6"

    /// The task: the replies I would most likely send to the newest message, best first, as many as
    /// really fit (one to three). The model decides what kinds of answers fit; options the message
    /// offers are usually them. The app may drop a last reply the model was unsure of
    /// (`ReplyScoring`).
    static func repliesTask(_ replies: ReplyRequest) -> String {
        let length = replies.minWords == replies.maxWords ? "about \(replies.maxWords) words"
            : "\(replies.minWords) to \(replies.maxWords) words"
        return """
            I am about to reply in the empty box I am typing in. Suggest the replies I would most likely \
            send, as me, to the newest message that is waiting for my answer in the reference material: up \
            to \(ReplyRequest.maxReplies), best first.
            First find that message: it is the last thing the other person (or the assistant) said to me, \
            usually right above the box. In a chat, lines starting with "Me:" are messages I sent, and lines \
            starting with "Them:" or a person's name are theirs: answer their newest message, never my own. \
            If my own message is the newest one, nothing is waiting for my reply. Questions I already answered further up are done; ignore them. Also \
            ignore the app's own prompts that are not part of the conversation (ratings, "How is it doing?", \
            tips, status panels, task lists and progress lines such as "1/3 - Look at how…").
            Then decide what I would really answer. When the message offers options (in words, as buttons \
            under it, or as a list), those options are usually my answers: start each reply with the \
            option's own words. Otherwise give the different answers I would really consider. Every reply \
            must answer that message; never turn its own request into a reply (if it says "check the console \
            and reply when done", a reply is "Done, it looks right", not "Check the console"). Each reply is \
            a different answer, not the same one in other words. Stop after one or two when no other real \
            answer fits.
            Each reply is one short sentence of \(length), in my voice and in the language of the message, \
            ready to send. Add a detail only when it helps (a time, what I will do next); never add a name \
            just to add one, and never the app's name. Do not invent facts that are not in the reference \
            material.
            The reference material was read off my screen by text recognition: it mixes the conversation \
            with the app's own labels and may have misread words (for example "suagested" for "suggested"). \
            Write every word correctly spelled: never copy a misread word.
            Output only the replies, one per line, best first: no numbers, quotation marks, labels or notes. \
            If nothing in the reference material is waiting for my reply, output only \(ReplyRequest.noneMarker).
            """
    }

    static let repliesReminder = "\n\nNow write the replies, one per line."
    static let repliesChinese = "\n\nThe message is in Chinese: write the replies in Chinese."
    static let repliesTraditional = "\n\nThe message is in Chinese: write the replies in Chinese, in Traditional "
        + "characters (繁體字), never Simplified."

    /// The newest part of the screen text, where the message being replied to usually is.
    static func latestScreenPart(_ screen: String) -> String { String(screen.suffix(400)) }

    /// For a chat whose screen text says who wrote each message ("Me: …", "Them: …" or a sender's
    /// name, from `ChatSides`): a closing line naming the newest message and whose it is, so the
    /// model answers their last message as me instead of continuing my own (a small model reads
    /// the labels in the task but still answered "are you almost here" as the late friend).
    ///
    /// Their list items and status lines (`isListOrStatus`) are never "their newest message": an app's
    /// progress checklist or "Thinking 41s" after their real last message would otherwise be answered.
    static func repliesSidesLine(screen: String?) -> String? {
        guard let screen else { return nil }
        var mine: String?, theirs: String?, lastIsMine = false
        for line in screen.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon], text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, label.count <= 30, !label.contains(where: \.isNumber), !text.isEmpty else { continue }
            // "Me" is `ChatSides.meLabel` (HunchScreen).
            if label == "Me" {
                mine = text
                lastIsMine = true
            } else if label.first?.isUppercase == true, !isListOrStatus(text) {
                theirs = text
                lastIsMine = false
            }
        }
        if lastIsMine, let mine {
            return "\n\nIn this chat my own message \"\(String(mine.prefix(120)))\" is the newest: nothing new is "
                + "waiting for my reply, so output only \(ReplyRequest.noneMarker)."
        }
        guard let theirs else { return nil }
        return "\n\nIn this chat their newest message is \"\(String(theirs.prefix(160)))\". Reply to it as me (the "
            + "\"Me:\" side), not as them."
    }

    /// A list item or a status row rather than a message (`ReplyQuestion.isListOrStatus`).
    static func isListOrStatus(_ text: String) -> Bool { ReplyQuestion.isListOrStatus(text) }

    /// Replies I sent to messages like this one before (learned replies): offered first when they fit.
    static func repliesLearnedLine(_ learned: [String]) -> String? {
        guard !learned.isEmpty else { return nil }
        let list = learned.prefix(3).map { "\"\($0.trimmingCharacters(in: .whitespaces))\"" }.joined(separator: ", ")
        return "\n\nTo messages like this one I usually reply: \(list). Offer those first when they fit this message."
    }

    /// A line naming the replies' language when the message is in Chinese: the writer's language list
    /// ("I write in: en") otherwise pulls the replies into English.
    static func repliesLanguageLine(screen: String?) -> String? {
        guard let screen, let share = hanShare(latestScreenPart(screen)), share >= 0.3 else { return nil }
        return HanScript.usesTraditional(latestScreenPart(screen)) ? repliesTraditional : repliesChinese
    }

    func frameReplies(_ request: WriteRequest, replies: ReplyRequest, profile: ModelProfile, budget: Int,
                      counter: any TokenCounting) -> FramedPrompt {
        let input = Self.redacted(request.context)
        let markers = profile.isInstruct ? profile.markers : nil
        var layout: [LayoutItem] = []
        if let markers {
            layout.append(.fixed(PromptSegment(text: markers.userOpen, kind: .control, stability: .stable)))
        }
        layout.append(.fixed(PromptSegment(text: Self.repliesTask(replies), kind: .control, stability: .stable,
                                           label: "task")))
        appendContext(input, to: &layout, counter: counter, screenLimit: input.screenTokenLimit)
        layout.append(.fixed(PromptSegment(text: Self.repliesReminder, kind: .control, stability: .perKeystroke)))
        if let sides = Self.repliesSidesLine(screen: input.screenContext) {
            layout.append(.fixed(PromptSegment(text: sides, kind: .control, stability: .perKeystroke)))
        }
        if let learned = Self.repliesLearnedLine(replies.learned) {
            layout.append(.fixed(PromptSegment(text: learned, kind: .control, stability: .perKeystroke,
                                               label: "learned replies")))
        }
        if let language = Self.repliesLanguageLine(screen: input.screenContext) {
            layout.append(.fixed(PromptSegment(text: language, kind: .control, stability: .perKeystroke)))
        }
        if let markers {
            layout.append(.fixed(PromptSegment(text: markers.turnClose, kind: .control, stability: .perKeystroke)))
            layout.append(.fixed(PromptSegment(text: markers.assistantOpen, kind: .control, stability: .perKeystroke)))
            if let off = markers.reasoningOff {
                layout.append(.fixed(PromptSegment(text: off, kind: .control, stability: .perKeystroke)))
            }
        } else {
            layout.append(.fixed(PromptSegment(text: "\n\n", kind: .control, stability: .perKeystroke)))
        }
        let assembled = FrameAssembler.assembleNoted(layout: layout, caretText: "", budget: budget, counter: counter)
        return FramedPrompt(segments: assembled.segments.filter { !$0.text.isEmpty }, requiredPrefix: "",
                            framerID: Self.repliesFrameID, style: markers == nil ? .document : .chatPrefill,
                            budgetNotes: assembled.notes)
    }
}
