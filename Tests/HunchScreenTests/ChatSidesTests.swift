import CoreGraphics
import Foundation
import HunchCore
import Testing
@testable import HunchScreen

// A chat window's conversation column from x 100 to 700 (600 pt wide), the message field under it.
// Messages are 16 pt lines; bubbles have 12 pt padding inside the column's edges.

private enum Place { case left, right, center }

/// A chat screen built top to bottom: each call adds a line, a bubble's lines stacked closely, a
/// gap between bubbles.
private struct ChatScreen {
    var columnMin: CGFloat = 100
    var columnMax: CGFloat = 700
    var lines: [OCRLine] = []
    var y: CGFloat = 40

    /// One bubble (several lines share its left edge; the longest sets its width).
    mutating func bubble(_ place: Place, _ texts: [String], height: CGFloat = 16, charWidth: CGFloat = 7.5,
                         maxWidth: CGFloat? = nil) {
        let cap = maxWidth ?? (columnMax - columnMin) * 0.7
        let widths = texts.map { min(cap, CGFloat($0.count) * charWidth) }
        let bubbleWidth = widths.max() ?? 0
        let x: CGFloat
        switch place {
        case .left: x = columnMin + 12
        case .right: x = columnMax - 12 - bubbleWidth
        case .center: x = (columnMin + columnMax - bubbleWidth) / 2
        }
        for (text, width) in zip(texts, widths) {
            lines.append(OCRLine(text: text, confidence: 0.9, rect: CGRect(x: x, y: y, width: width, height: height)))
            y += height + 4
        }
        y += 14
    }

    /// A sender's name in smaller type just above their bubble (group chats).
    mutating func name(_ text: String) {
        lines.append(OCRLine(text: text, confidence: 0.9,
                             rect: CGRect(x: columnMin + 12, y: y, width: CGFloat(text.count) * 6, height: 12)))
        y += 15
    }

    /// A short line flush with the right edge under the writer's last bubble ("Delivered").
    mutating func status(_ text: String) {
        let width = CGFloat(text.count) * 6
        lines.append(OCRLine(text: text, confidence: 0.9,
                             rect: CGRect(x: columnMax - 12 - width, y: y - 12, width: width, height: 12)))
        y += 6
    }

    var field: CGRect { CGRect(x: columnMin, y: y + 10, width: columnMax - columnMin, height: 36) }

    func text(sides: Bool = true) -> String? {
        ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: columnMin + 10, y: field.midY), field: field,
                                   maxCharacters: 4000, chatSides: sides)?.text
    }
}

// MARK: - Two-sided chats

@Test func messagesOneToOneLabelsBothSides() {
    // The reported case: the writer asked "are you almost here", the other person answered.
    var s = ChatScreen()
    s.bubble(.center, ["Today 6:14 PM"], height: 12)
    s.bubble(.left, ["leaving now, traffic is bad"])
    s.bubble(.right, ["are you almost here😬"])
    s.status("Delivered")
    s.bubble(.left, ["sorry yeah"])
    #expect(s.text() == """
        Today 6:14 PM
        Them: leaving now, traffic is bad
        Me: are you almost here😬
        Delivered
        Them: sorry yeah
        """)
    // Off: the flat lines as before.
    #expect(s.text(sides: false) == """
        Today 6:14 PM
        leaving now, traffic is bad
        are you almost here😬
        Delivered
        sorry yeah
        """)
}

@Test func multiLineBubbleBecomesOneLabeledLine() {
    var s = ChatScreen()
    s.bubble(.left, ["did you book the table"])
    s.bubble(.right, ["yes for 7, under my name, and I asked for", "the one by the window"])
    s.bubble(.left, ["perfect"])
    #expect(s.text() == """
        Them: did you book the table
        Me: yes for 7, under my name, and I asked for the one by the window
        Them: perfect
        """)
}

@Test func groupChatUsesSenderNames() {
    var s = ChatScreen()
    s.name("Jamie")
    s.bubble(.left, ["Who's in for trivia tomorrow"])
    s.bubble(.left, ["it starts at 8"])
    s.name("Leo")
    s.bubble(.left, ["in"])
    s.bubble(.right, ["me too, I'll grab a table"])
    s.name("Jamie")
    s.bubble(.left, ["Alex can you bring the buzzer"])
    #expect(s.text() == """
        Jamie: Who's in for trivia tomorrow
        Jamie: it starts at 8
        Leo: in
        Me: me too, I'll grab a table
        Jamie: Alex can you bring the buzzer
        """)
}

@Test func traditionalChineseLineChat() {
    var s = ChatScreen()
    s.bubble(.center, ["上午 10:02"], height: 12)
    s.bubble(.left, ["你到了嗎？"], charWidth: 16)
    s.bubble(.right, ["快到了，再五分鐘"], charWidth: 16)
    s.status("已讀")
    s.bubble(.left, ["好，我在門口等你"], charWidth: 16)
    #expect(s.text() == """
        上午 10:02
        Them: 你到了嗎？
        Me: 快到了，再五分鐘
        已讀
        Them: 好，我在門口等你
        """)
}

@Test func wideWindowKeepsSides() {
    var s = ChatScreen(columnMin: 300, columnMax: 2200)
    s.bubble(.left, ["are we still on for lunch"], maxWidth: 1200)
    s.bubble(.right, ["yes, 12:30 at the usual place"], maxWidth: 1200)
    s.bubble(.left, ["see you there"], maxWidth: 1200)
    #expect(s.text() == """
        Them: are we still on for lunch
        Me: yes, 12:30 at the usual place
        Them: see you there
        """)
}

@Test func aiChatFullWidthReplyAndIndentedUserBubble() {
    // Claude desktop: the reply runs the column's full width from its left edge; the writer's
    // message is a bubble flush right, indented about a sixth of the column, its text ragged.
    var s = ChatScreen(columnMin: 100, columnMax: 1400)
    s.bubble(.left, ["The flakiness comes from the test sharing a mock clock with the one before it, so the",
                     "next test inherits fake timers."], maxWidth: 1300)
    s.bubble(.left, ["Option 1 is the safer default since it protects every test in the suite."], maxWidth: 1300)
    let top = s.y
    s.lines.append(OCRLine(text: "Option 1 makes sense, but we also have tests that keep fake timers across a describe",
                           confidence: 0.9, rect: CGRect(x: 330, y: top, width: 1040, height: 16)))
    s.lines.append(OCRLine(text: "block, will that break them", confidence: 0.9,
                           rect: CGRect(x: 330, y: top + 20, width: 330, height: 16)))
    s.y = top + 50
    s.bubble(.left, ["It would, but only for those blocks."], maxWidth: 1300)
    #expect(s.text() == """
        Them: The flakiness comes from the test sharing a mock clock with the one before it, so the next test inherits fake timers.
        Them: Option 1 is the safer default since it protects every test in the suite.
        Me: Option 1 makes sense, but we also have tests that keep fake timers across a describe block, will that break them
        Them: It would, but only for those blocks.
        """)
}

// MARK: - Layouts that stay unlabeled

@Test func leftAlignedListWithHeadersIsNotLabeled() {
    // Slack/Discord: everyone's messages start at the left edge under a name header.
    var s = ChatScreen()
    for (who, what) in [("Nora 10:14 AM", "staging is green again, the cache flush fixed the 502s"),
                        ("Omar 10:15 AM", "can someone confirm the pricing page copy is final? legal pinged me"),
                        ("Alex 10:16 AM", "yes, final as of this morning")] {
        s.bubble(.left, [who])
        s.bubble(.left, [what], maxWidth: 576)
    }
    #expect(s.text() == s.text(sides: false))
    #expect(!(s.text() ?? "").contains("Me:"))
}

@Test func oneSidedScreenIsNotLabeled() {
    // Only the other person's messages in view: no right side, so nothing is labeled.
    var s = ChatScreen()
    s.bubble(.left, ["did you see the game"])
    s.bubble(.left, ["unreal ending"])
    #expect(s.text() == "did you see the game\nunreal ending")
}

@Test func indentedDocumentIsNotTwoSided() {
    // Quoted and indented blocks that fit neither side (an email thread in a chat-like place).
    var s = ChatScreen()
    s.bubble(.left, ["Thanks for sending this over."], maxWidth: 576)
    s.lines.append(OCRLine(text: "> On Monday you wrote that the draft was ready", confidence: 0.9,
                           rect: CGRect(x: 160, y: s.y, width: 340, height: 16)))
    s.y += 34
    s.lines.append(OCRLine(text: "> and that legal had signed off on it", confidence: 0.9,
                           rect: CGRect(x: 220, y: s.y, width: 300, height: 16)))
    s.y += 34
    s.bubble(.right, ["Sent from my phone"])
    s.bubble(.left, ["Let me know."])
    #expect(!(s.text() ?? "").contains("Me:"))
}

// MARK: - Pieces

@Test func chromeLinesAreNeverLabeled() {
    for line in ["Delivered", "Read 9:41 AM", "Seen", "已讀 6", "已送達", "Today 6:14 PM", "10:02", "上午 10:03",
                 "Loved “guilty, buying more today”", "已將「我要煮紅燒肉」加上愛心", "👍"] {
        #expect(ChatSides.isUnlabeled(line), "\(line)")
    }
    for line in ["read the chapter yet?", "sent you the link", "ok", "我可以", "Seen it twice already"] {
        #expect(!ChatSides.isUnlabeled(line), "\(line)")
    }
}

@Test func appliesOnlyInChatPlaces() {
    #expect(ChatSides.applies(surface: .chat, bundleID: "com.apple.MobileSMS"))
    #expect(ChatSides.applies(surface: .unknown, bundleID: "com.anthropic.claudefordesktop"))
    #expect(ChatSides.applies(surface: .unknown, bundleID: "jp.naver.line.mac"))
    #expect(ChatSides.applies(surface: .unknown, bundleID: "com.google.Chrome", urlHost: "web.whatsapp.com"))
    #expect(!ChatSides.applies(surface: .email, bundleID: "com.apple.mail"))
    #expect(!ChatSides.applies(surface: .document, bundleID: "com.apple.TextEdit"))
    #expect(!ChatSides.applies(surface: .unknown, bundleID: "com.google.Chrome", urlHost: "mail.google.com"))
}

// MARK: - Real layouts (rects measured from screenshots, text replaced with generic text)

/// Lines given as (text, minX, maxX, top, height), screenshot pixels, top-left origin.
private func real(_ rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)], field: CGRect,
                  bubbleApp: Bool = false) -> String? {
    let lines = rows.map { OCRLine(text: $0.0, confidence: 0.9, rect: CGRect(x: $0.1, y: $0.3, width: $0.2 - $0.1, height: $0.4)) }
    return ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: field.minX + 10, y: field.midY), field: field,
                                      maxCharacters: 4000, chatSides: true, bubbleApp: bubbleApp)?.text
}

@Test func realMessagesNarrowWindow() {
    // Messages at 648 px wide: a wrapped question on the left, a wrapped answer on the right with
    // ragged lines, centered day stamps, "Delivered" under the newest message.
    let text = real([
        ("Sunday 1:37 PM", 246, 393, 2, 20),
        ("Hey Alex, besides", 46, 301, 53, 24),
        ("friday, is there any day", 46, 386, 85, 24),
        ("I could leave at 4", 46, 330, 117, 24),
        ("instead?", 46, 145, 149, 24),
        ("Monday 10:16 AM", 238, 405, 219, 20),
        ("before noon I only need one", 257, 596, 273, 24),
        ("person so not this week. we", 257, 572, 305, 24),
        ("do need someone", 257, 513, 337, 24),
        ("thursday 2-8 but they will", 257, 562, 369, 24),
        ("also have to close up", 257, 578, 401, 24),
        ("Today 5:05 PM", 251, 392, 471, 20),
        ("are you almost here", 321, 560, 524, 24),
        ("Delivered", 497, 589, 574, 18),
    ], field: CGRect(x: 88, y: 612, width: 472, height: 60))
    #expect(text == """
        Sunday 1:37 PM
        Them: Hey Alex, besides friday, is there any day I could leave at 4 instead?
        Monday 10:16 AM
        Me: before noon I only need one person so not this week. we do need someone thursday 2-8 but they will also have to close up
        Today 5:05 PM
        Me: are you almost here
        Delivered
        """)
}

@Test func realMessagesWideWindow() {
    let text = real([
        ("Hey Alex, besides friday, is there any day I could leave at 4 instead of staying late?", 34, 1018, 34, 26),
        ("Monday 10:16 AM", 853, 1021, 105, 22),
        ("before noon I only need one person so not this week. we do need someone thursday 2-8 but", 687, 1834, 157, 26),
        ("they will also have to close up", 687, 1110, 189, 26),
        ("Today 5:05 PM", 867, 1008, 260, 22),
        ("are you almost here", 1565, 1803, 312, 26),
        ("Delivered", 1741, 1833, 363, 22),
        ("sorry yeah", 34, 161, 412, 26),
    ], field: CGRect(x: 72, y: 488, width: 1731, height: 58))
    #expect(text == """
        Them: Hey Alex, besides friday, is there any day I could leave at 4 instead of staying late?
        Monday 10:16 AM
        Me: before noon I only need one person so not this week. we do need someone thursday 2-8 but they will also have to close up
        Today 5:05 PM
        Me: are you almost here
        Delivered
        Them: sorry yeah
        """)
}

@Test func realMessagesWithPhotoText() {
    // Text read off a photo in the other person's bubble sits at neither edge: left unlabeled, and
    // it doesn't stop the messages around it from being labeled.
    let text = real([
        ("For closing, the cash I take out goes in as a deposit, right?", 50, 753, 35, 26),
        ("ABC 248", 98, 318, 180, 50),
        ("Actual cash in drawer", 372, 680, 268, 30),
        ("$130.00", 543, 659, 357, 28),
        ("00", 376, 422, 1012, 34),
        ("Okay sorry quick question, do I enter what is left (130) or the total", 50, 874, 1106, 26),
        ("amount in the drawer (130+12)", 50, 373, 1138, 26),
        ("It won't let me finish if I don't", 50, 469, 1204, 26),
        ("no need to finish it", 1160, 1430, 1280, 26),
        ("just print the report", 1187, 1421, 1402, 26),
        ("Okay thank you", 50, 237, 1477, 26),
    ], field: CGRect(x: 80, y: 1540, width: 1320, height: 58))
    #expect(text == """
        Them: For closing, the cash I take out goes in as a deposit, right?
        ABC 248
        Actual cash in drawer
        $130.00
        00
        Them: Okay sorry quick question, do I enter what is left (130) or the total amount in the drawer (130+12)
        Them: It won't let me finish if I don't
        Me: no need to finish it
        Me: just print the report
        Them: Okay thank you
        """)
}

@Test func realMessagesWithThreadReplies() {
    // A file card, a thread ("4 Replies") with its quoted message, a tapback badge, and the
    // writer's message whose closing emoji OCR didn't read (it stops short of the right edge). The
    // thread's first copy of the quoted message goes as a duplicate, as before.
    let text = real([
        ("NOOOOOO", 45, 183, 47, 26),
        ("Ok but like why", 45, 209, 113, 26),
        ("IMG_0520.heic", 188, 352, 222, 24),
        ("Image · 20 KB", 188, 321, 255, 20),
        ("This sounds like a phishing message", 45, 504, 410, 26),
        ("4 Replies", 53, 142, 463, 22),
        ("I haven't memorized my new number yet it's gonna be so annoying", 573, 1377, 520, 26),
        ("This sounds like a phishing message", 37, 403, 640, 20),
        ("4 Replies", 69, 158, 683, 22),
        ("HA", 511, 540, 738, 14),
        ("I had to copy and paste to multiple people, don't have time to customize", 545, 1416, 785, 26),
        ("the message lol", 545, 734, 817, 26),
        ("Would it be better if I said Hello manager, this is Alex, I", 586, 1416, 883, 26),
        ("just got a new number", 586, 853, 915, 26),
        ("And then also send", 1185, 1415, 981, 26),
    ], field: CGRect(x: 82, y: 1040, width: 1303, height: 60))
    #expect(text == """
        Them: NOOOOOO
        Them: Ok but like why
        IMG_0520.heic
        Image · 20 KB
        Me: I haven't memorized my new number yet it's gonna be so annoying
        Them: This sounds like a phishing message
        4 Replies
        HA
        Me: I had to copy and paste to multiple people, don't have time to customize the message lol
        Me: Would it be better if I said Hello manager, this is Alex, I just got a new number
        Me: And then also send
        """)
}

@Test func realClaudeDesktop() {
    // Vision's own rects from a Claude desktop window: the reply and the next-step card start at the
    // left; the writer's message is flush right, indented, with lines of quite different heights.
    let text = real([
        ("Should I label only the two-sided bubble apps first, as the brief says, or bring the other", 24, 1256, 45, 30),
        ("labels back too?", 22, 229, 83, 22),
        ("The old work is still in git: added in one commit, removed in", 52, 873, 232, 29),
        ("another on Nov 2. It labelled lists from header lines and", 53, 828, 274, 24),
        ("learned your handle from sent messages, and the evals showed no", 51, 838, 310, 29),
        ("gain. Nothing is built yet on this branch.", 53, 523, 345, 26),
        ("Label only two-sided bubble apps first, or the lists as well?", 53, 818, 401, 35),
        ("Bubble apps first. Also in the desktop app my messages also sit on the right, although", 264, 1327, 546, 37),
        ("they're definitely not as separated as other bubble apps", 264, 964, 588, 26),
    ], field: CGRect(x: 24, y: 680, width: 1330, height: 80))
    #expect(text == """
        Them: Should I label only the two-sided bubble apps first, as the brief says, or bring the other labels back too?
        Them: The old work is still in git: added in one commit, removed in another on Nov 2. It labelled lists from header lines and learned your handle from sent messages, and the evals showed no gain. Nothing is built yet on this branch.
        Them: Label only two-sided bubble apps first, or the lists as well?
        Me: Bubble apps first. Also in the desktop app my messages also sit on the right, although they're definitely not as separated as other bubble apps
        """)
}

@Test func realClaudeCodeStatusRowAboveTheBoxIsNotTheWriter() {
    // Claude desktop's Code tab: above the text box, a usage panel and a status bar sit on one row
    // that OCR reads as three fragments far apart. Joined, the row reaches the column's right edge
    // and looked like the writer's newest message, so replies saw no message to answer.
    let text = real([
        ("The inline chips now have a solid background, so placeholder text no longer shows through.", 520, 1131, 927, 15),
        ("Please check the chips again and reply when done.", 520, 1086, 960, 15),
        ("The inline bubbles probably need opaque backgrounds. A lot of apps have text in the", 633, 1162, 1000, 14),
        ("field already even when it's empty, so the option is kind of hard to read", 630, 1150, 1019, 16),
        ("Check the inline chips in that app again and report back?", 530, 866, 1271, 12),
        ("Done testing", 538, 618, 1306, 16),
        ("Skip testing", 678, 751, 1307, 15),
        ("26%", 639, 662, 1506, 10),
        ("v Render light and dark to check", 695, 898, 1508, 14),
        ("Opus 5.5 • Medium • Auto", 1030, 1180, 1508, 14),
    ], field: CGRect(x: 541, y: 1562, width: 588, height: 20))
    let lines = text?.components(separatedBy: "\n") ?? []
    #expect(lines.contains("Me: The inline bubbles probably need opaque backgrounds. A lot of apps have text in the "
                           + "field already even when it's empty, so the option is kind of hard to read"))
    #expect(lines.contains("Them: Check the inline chips in that app again and report back?"))
    #expect(!lines.contains { $0.hasPrefix("Me:") && $0.contains("Render") })
}

@Test func rowsJoinedAcrossWideGapsAreSpread() {
    let rows = ScreenTextPipeline.mergingRows([
        ("Sounds good", CGRect(x: 100, y: 10, width: 90, height: 16), 0),
        ("🙂", CGRect(x: 205, y: 10, width: 10, height: 16), 0),
        ("Status", CGRect(x: 100, y: 60, width: 50, height: 14), 0),
        ("Auto", CGRect(x: 250, y: 60, width: 40, height: 14), 0),
    ])
    #expect(rows.first { $0.text.hasPrefix("Sounds") }?.spread == false)
    #expect(rows.first { $0.text.hasPrefix("Status") }?.spread == true)
}

/// Claude Code with only the assistant's messages on screen (the writer's scrolled off), and the
/// status row above the text box. Rects from a real capture, text replaced.
private let oneSidedClaudeRows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
    ("I fixed the labels: the status bar above the text box is no longer read as yours.", 520, 1126, 697, 14),
    ("The fix is committed and merged. All tests pass, and the new build is installed.", 520, 1126, 715, 17),
    ("Ran 2 commands", 520, 641, 760, 12),
    ("Cause: the row above the box was read as three separate pieces, and joined, it", 520, 1129, 782, 14),
    ("reached the right edge, which is how your own messages look.", 520, 1101, 803, 14),
    ("Please check: wait for replies with the status bar showing.", 520, 1124, 1117, 14),
    ("Retest replies with the status bar showing, and report back?", 530, 1026, 1271, 14),
    ("Done testing", 538, 615, 1306, 14),
    ("Skip testing", 641, 714, 1308, 15),
    ("27%", 639, 662, 1506, 10),
    ("v Merge into replies branch, build, install", 695, 948, 1508, 16),
    ("Opus 5.5 • Medium • Auto", 1030, 1180, 1508, 14),
]

@Test func oneSidedScreenInABubbleAppIsTheirs() {
    let field = CGRect(x: 541, y: 1562, width: 588, height: 20)
    let text = real(oneSidedClaudeRows, field: field, bubbleApp: true) ?? ""
    let lines = text.components(separatedBy: "\n")
    #expect(lines.contains("Them: Retest replies with the status bar showing, and report back?"))
    #expect(!lines.contains { $0.hasPrefix("Me:") })
    #expect(!lines.contains { $0.hasPrefix("Them:") && $0.contains("Opus") })
    // Outside bubble apps a one-sided screen stays unlabeled.
    #expect(!(real(oneSidedClaudeRows, field: field) ?? "").contains("Them:"))
}

@Test func oneSidedRightAlignedScreenIsNotTheirs() {
    // Only the writer's bubbles, all the same width: they share the left edge, but none ends short of
    // the right edge, so nothing marks them as the other side's.
    let lines: [(text: String, rect: CGRect)] = [
        ("Sounds good, see you at six then", CGRect(x: 400, y: 100, width: 300, height: 16)),
        ("I'll bring the charger you lent me", CGRect(x: 402, y: 140, width: 298, height: 16)),
    ]
    #expect(ChatSides.assign(lines, bubbleApp: true) == nil)
}

@Test func bubbleAppsExcludeListChats() {
    #expect(ChatSides.isBubbleApp(bundleID: "com.apple.MobileSMS"))
    #expect(ChatSides.isBubbleApp(bundleID: "com.google.Chrome", urlHost: "web.whatsapp.com"))
    #expect(!ChatSides.isBubbleApp(bundleID: "com.tinyspeck.slackmacgap"))
    #expect(!ChatSides.isBubbleApp(bundleID: "com.hnc.Discord"))
    // AI chats whose own messages sit right-aligned; Cursor and Hermes put them on the left.
    #expect(ChatSides.isBubbleApp(bundleID: "com.openai.codex"))
    #expect(ChatSides.isBubbleApp(bundleID: "ai.elementlabs.lmstudio"))
    #expect(ChatSides.applies(surface: .unknown, bundleID: "ai.elementlabs.lmstudio"))
    #expect(!ChatSides.isBubbleApp(bundleID: "com.nousresearch.hermes"))
}

@Test func realClaudeCodeCloseStatusRowIsNotTheWriter() {
    // Claude desktop's Code tab while the assistant works: its reply and task list on the left, the
    // writer's last message indented on the right, then a timer row and a status row above the box.
    // The status row's parts sit too close for `spread`; it starts indented and reaches the right
    // edge, so it looked like the writer's newest message. Rects from a real capture, text replaced.
    let text = real([
        ("Should the labels apply to one-sided screens in chat apps only, or nowhere?", 517, 1082, 782, 14),
        ("Here is what the replay shows: the status-bar fix works. Now only my", 532, 935, 860, 14),
        ("messages are on screen, and those get no speaker labels yet.", 532, 912, 881, 12),
        ("Label one-sided screens in known chat apps?", 532, 917, 944, 15),
        ("Chat apps only", 1036, 1174, 1036, 18),
        ("Ran 4 commands ›", 517, 640, 1100, 16),
        ("Tests pass. Let me look at the labeled output for that screen, since the buttons", 520, 1129, 1173, 16),
        ("might end up counted as the newest message:", 517, 916, 1192, 15),
        ("• Label one-sided screens", 534, 820, 1278, 12),
        ("* Test with the replayed capture", 530, 735, 1301, 16),
        ("* Commit, merge and install", 532, 781, 1326, 17),
        ("••• 1m 26s • 2.8K tokens", 519, 691, 1380, 17),
        ("1/3 • Label one-sided screens", 693, 1004, 1508, 12),
        ("Opus 5.5 • Medium • Auto", 1030, 1180, 1508, 12),
    ], field: CGRect(x: 541, y: 1562, width: 588, height: 20))
    let lines = text?.components(separatedBy: "\n") ?? []
    #expect(lines.contains("Me: Chat apps only"))
    #expect(!lines.contains { $0.hasPrefix("Me:") && $0.contains("Auto") })
    #expect(!lines.contains { $0.hasPrefix("Them:") && $0.contains("tokens") })
    #expect(lines.last { $0.hasPrefix("Me:") || $0.hasPrefix("Them:") }?.hasPrefix("Them:") == true)
}

@Test func statusRowsOfBulletSeparatedParts() {
    #expect(ChatSides.isStatusRow("Opus 5.5 • Medium • Auto"))
    #expect(ChatSides.isStatusRow("1/3 • Label one-sided screens Opus 5.5 • Medium • Auto"))
    #expect(ChatSides.isStatusRow("••• 1m 26s • 2.8K tokens"))
    #expect(ChatSides.isStatusRow("• • 15s • Thinking"))
    #expect(ChatSides.isStatusRow("• Other 3 • Run 1 • Edit 1"))
    // List items and messages that quote a status row are not.
    #expect(!ChatSides.isStatusRow("• Label one-sided screens"))
    #expect(!ChatSides.isStatusRow("Sounds good • see you at the station"))
    #expect(!ChatSides.isStatusRow("It read 'Opus 5.5 • Medium • Auto' as one line, which looked like your own message"))
}

// MARK: - Sent messages

@Test func sentMessageMatchesThroughOCRSlips() {
    let sent = [ChatSides.matchKey("Tested. Seems like the speaker labels are just failing to tag the right speaker now.")]
    #expect(ChatSides.matches(ChatSides.matchKey("Tested. Seems like the speaker labels are just failing to"), sent))
    // A word or a short quote of the message is not a match.
    #expect(!ChatSides.matches(ChatSides.matchKey("the speaker labels"), sent))
    #expect(!ChatSides.matches(ChatSides.matchKey("context"), [ChatSides.matchKey("I checked the screen context and this")]))
    #expect(ChatSides.matches(ChatSides.matchKey("Tested. Seems Iike the speaker labels are just failing to tag the rigbt speaker now."), sent))
    #expect(!ChatSides.matches(ChatSides.matchKey("Retest replies with the status bar showing"), sent))
    #expect(!ChatSides.matches(ChatSides.matchKey("ok"), [ChatSides.matchKey("ok")]))
}

/// Their reply at the left, the writer's message indented on the right, then a row of app chrome
/// that also sits indented against the right edge (no bullets, no wide gaps).
private let chromeBelowMine: [(text: String, rect: CGRect)] = [
    ("Here is the plan for the release next week, with the risky parts first.", CGRect(x: 20, y: 100, width: 900, height: 16)),
    ("Sounds good, ship the docs change first please", CGRect(x: 600, y: 160, width: 400, height: 16)),
    ("Thinking about the release order now", CGRect(x: 640, y: 220, width: 360, height: 16)),
]

@Test func unmatchedMeBelowTheNewestSentMessageIsVetoed() {
    // Layout alone takes the chrome row for the writer's newest message.
    let plain = ChatSides.assign(chromeBelowMine)
    #expect(plain?.map(\.speaker) == ["Them", "Me", "Me"])
    let withSent = ChatSides.assign(chromeBelowMine, sent: ["Sounds good, ship the docs change first please!"])
    #expect(withSent?.map(\.speaker) == ["Them", "Me", nil])
    #expect(withSent?[1].confirmedBySent == true)
    #expect(withSent?[2].vetoedBySent == true)
}

@Test func sentMessageConfirmsMeWhereLayoutCannotTell() {
    // The writer's short message isn't indented enough for layout to call it theirs or mine.
    let lines: [(text: String, rect: CGRect)] = [
        ("Can you send me the address for tonight please", CGRect(x: 20, y: 100, width: 500, height: 16)),
        ("It's on Elm Street, the blue house", CGRect(x: 60, y: 160, width: 940, height: 16)),
        ("Great thanks, see you there tonight", CGRect(x: 20, y: 220, width: 400, height: 16)),
    ]
    #expect(ChatSides.assign(lines) == nil)
    let a = ChatSides.assign(lines, sent: ["It's on Elm Street, the blue house"])
    #expect(a?.map(\.speaker) == ["Them", "Me", "Them"])
}

@Test func sentMessagesDontLabelListChats() {
    // A list-style chat: everything at the left edge. A match there doesn't make it two-sided.
    let lines: [(text: String, rect: CGRect)] = [
        ("Deploy is done, the dashboards look fine", CGRect(x: 20, y: 100, width: 500, height: 16)),
        ("Great, I will tell the support team now", CGRect(x: 20, y: 160, width: 480, height: 16)),
    ]
    #expect(ChatSides.assign(lines, sent: ["Great, I will tell the support team now"]) == nil)
}

@Test func chatDropsLinesBelowTheTextBox() {
    // Claude Code: a model picker and usage note under the text box belong to the app.
    let field = CGRect(x: 541, y: 1562, width: 588, height: 20)
    let rows: [(String, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        ("Here is the plan for the release, with the risky parts first.", 520, 1126, 1200, 14),
        ("Sounds good, ship the docs change first please", 760, 1160, 1260, 14),
        ("Opus 5.5 Medium", 1020, 1124, 1604, 12),
        ("Get more usage", 560, 660, 1604, 12),
    ]
    let chat = real(rows, field: field) ?? ""
    #expect(!chat.contains("Opus") && !chat.contains("usage"))
    // Outside chats (an email with the quoted thread under the reply box) nothing is dropped.
    let lines = rows.map { OCRLine(text: $0.0, confidence: 0.9, rect: CGRect(x: $0.1, y: $0.3, width: $0.2 - $0.1, height: $0.4)) }
    let doc = ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: field.minX + 10, y: field.midY), field: field,
                                         maxCharacters: 4000)?.text ?? ""
    #expect(doc.contains("Get more usage"))
}

// MARK: - Sender names in Messages group chats (geometry from real reads, text made up)

/// Lines as text recognition read them in a Messages group chat: column x 415-1290, the field under
/// it at y 970. Name lines are ~27 pt wide; heights vary with the letters.
private func messagesGroup(_ rows: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, text: String)],
                           senderNames: Bool = true) -> String? {
    let lines = rows.map { OCRLine(text: $0.text, confidence: 1, rect: CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }
    let field = CGRect(x: 408, y: 970, width: 881, height: 31)
    return ScreenTextPipeline.process(lines: lines, caret: CGPoint(x: 413, y: 985), field: field, maxCharacters: 4000,
                                      chatSides: true, bubbleApp: true, senderNames: senderNames)?.text
}

@Test func nameReadAsTallAsItsBubbleStillNamesIt() {
    // "Avery" read 13 pt over a 12 pt "Oh no": not smaller, but much closer to its bubble than bubbles
    // are to each other. Before, it became a message of the previous sender, who also got Avery's lines.
    #expect(messagesGroup([
        (416, 407, 29, 9, "Robin"), (416, 432, 253, 12, "can someone let me in pls"),
        (415, 467, 29, 13, "Avery"), (417, 491, 58, 12, "Oh no"), (415, 524, 50, 14, "Coming"),
        (1234, 559, 104, 18, "i'm not home"),
        (416, 599, 27, 9, "Robin"), (415, 624, 78, 14, "thank youuu"),
    ]) == """
        Robin: can someone let me in pls
        Avery: Oh no
        Avery: Coming
        Me: i'm not home
        Robin: thank youuu
        """)
}

@Test func nameOverShortLettersBubble() {
    // "ah" and "sure" read as small as the name above them (10 pt); the screen's usual line is 14 pt.
    #expect(messagesGroup([
        (416, 300, 400, 14, "just a heads up, my friend's cat is staying with us this week"),
        (1000, 340, 280, 14, "ok! my friend's car is here tonight too"),
        (416, 380, 27, 10, "Robin"), (416, 405, 16, 10, "ah"), (416, 438, 29, 10, "sure"),
        (1050, 474, 203, 14, "it'll be gone by tomorrow"),
    ]) == """
        Them: just a heads up, my friend's cat is staying with us this week
        Me: ok! my friend's car is here tonight too
        Robin: ah
        Robin: sure
        Me: it'll be gone by tomorrow
        """)
}

@Test func nameOverStickerIsNotAMessage() {
    // Avery sent a sticker (nothing to read): their name line is followed by Robin's name, and must
    // neither become a message nor rename the lines after it.
    #expect(messagesGroup([
        (416, 300, 27, 9, "Avery"), (416, 324, 253, 12, "who's taking the bins out"),
        (416, 360, 27, 9, "Robin"), (416, 384, 120, 12, "not me lol"),
        (416, 420, 27, 9, "Avery"),
        (416, 560, 27, 9, "Robin"), (416, 584, 140, 12, "ok fine I'll do it"),
    ]) == """
        Avery: who's taking the bins out
        Robin: not me lol
        Robin: ok fine I'll do it
        """)
}

@Test func oneWordMessagesAreNotNames() {
    // A capitalized one-word message sits as far from the next bubble as any two bubbles do.
    #expect(messagesGroup([
        (416, 300, 27, 9, "Robin"), (416, 324, 253, 12, "anyone up for dinner"),
        (416, 360, 27, 9, "Avery"), (416, 384, 50, 13, "Sure"), (416, 417, 140, 13, "where though"),
    ]) == """
        Robin: anyone up for dinner
        Avery: Sure
        Avery: where though
        """)
}

@Test func aiChatHasNoSenderNames() {
    // A bold heading in an assistant's reply looks like a name over a paragraph; AI chats get none.
    let rows: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, text: String)] = [
        (1000, 300, 280, 14, "did the fix work?"),
        (416, 340, 80, 11, "Where it went"), (416, 356, 600, 14, "The change is on master and the installed app has it."),
        (416, 400, 80, 11, "Still open"), (416, 416, 600, 14, "The second screen still needs a check from you."),
    ]
    #expect(messagesGroup(rows, senderNames: false) == """
        Me: did the fix work?
        Them: Where it went The change is on master and the installed app has it.
        Them: Still open The second screen still needs a check from you.
        """)
    #expect(ChatSides.hasSenderNames(surface: .chat, bundleID: "com.apple.MobileSMS"))
    #expect(!ChatSides.hasSenderNames(surface: .chat, bundleID: "com.anthropic.claudefordesktop"))
    #expect(!ChatSides.hasSenderNames(surface: .chat, bundleID: "com.google.Chrome", urlHost: "chatgpt.com"))
}
