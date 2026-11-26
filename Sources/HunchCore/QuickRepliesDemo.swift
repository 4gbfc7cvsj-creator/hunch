/// The welcome tour's Quick replies demo, as data: a few short conversations, and the steps each one
/// plays (the message arrives, the replies show, Tab moves the highlight to the reply picked, Return
/// puts it in the box). Pure, so the script is testable without the UI.
public enum QuickRepliesDemo {
    /// A message on screen, the replies offered for it, and the one the demo picks.
    public struct Conversation: Sendable, Equatable {
        public let sender: String
        public let message: String
        public let replies: [String]
        public let picked: Int

        public init(sender: String, message: String, replies: [String], picked: Int) {
            self.sender = sender
            self.message = message
            self.replies = replies
            self.picked = picked
        }
    }

    /// What the demo box shows.
    public enum Phase: Sendable, Equatable {
        /// An empty chat.
        case empty
        /// Their message is on screen, the box is still empty.
        case message
        /// The replies are showing; `highlighted` is the one Tab picked (none before the first Tab).
        case replies(highlighted: Int?)
        /// The picked reply is in the box (nothing is sent).
        case inserted
    }

    public enum Key: Sendable, Equatable { case tab, `return` }

    /// One step of a conversation: what shows after it, and the key pressed to get there.
    public struct Step: Sendable, Equatable {
        public let phase: Phase
        public let key: Key?

        public init(_ phase: Phase, key: Key? = nil) {
            self.phase = phase
            self.key = key
        }
    }

    /// The steps of `c`, in order. The highlight moves the way the real bubble's does (`ReplyPicker`).
    public static func steps(_ c: Conversation) -> [Step] {
        var out = [Step(.message), Step(.replies(highlighted: nil))]
        var picker = ReplyPicker(replies: c.replies)
        for _ in c.replies.indices {
            picker.next()
            out.append(Step(.replies(highlighted: picker.highlighted), key: .tab))
            if picker.highlighted == c.picked { break }
        }
        out.append(Step(.inserted, key: .return))
        return out
    }

    /// The looping script: short replies, so every one fits a chip without being cut.
    public static let script: [Conversation] = [
        Conversation(sender: "Sam", message: "Are you still up for lunch on Friday?",
                     replies: ["Yes, see you then!", "Can we do Saturday?", "Sorry, I can\u{2019}t make it"], picked: 0),
        Conversation(sender: "Jordan", message: "Could you send me the slides before the meeting?",
                     replies: ["Sure, sending now", "Will do by noon", "Which version?"], picked: 1),
        Conversation(sender: "Taylor", message: "Thanks so much for your help today!",
                     replies: ["Anytime!", "Happy to help", "Glad it worked out"], picked: 2),
    ]
}
