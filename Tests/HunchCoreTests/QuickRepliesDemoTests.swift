import Testing
@testable import HunchCore

@Suite struct QuickRepliesDemoTests {
    typealias Demo = QuickRepliesDemo

    @Test func everyConversationOffersUpToThreeShortRepliesAndPicksOne() {
        for c in Demo.script {
            #expect((1...ReplyRequest.maxReplies).contains(c.replies.count))
            #expect(c.replies.indices.contains(c.picked))
            // Short enough for a chip that isn't highlighted (about 220 pt at 13 pt).
            #expect(c.replies.allSatisfy { $0.count <= 28 })
            #expect(Set(c.replies).count == c.replies.count)
        }
    }

    @Test func stepsShowTheMessageThenTheRepliesThenTabToThePickThenReturn() {
        for c in Demo.script {
            let steps = Demo.steps(c)
            #expect(steps.first == Demo.Step(.message))
            #expect(steps[1] == Demo.Step(.replies(highlighted: nil)))
            #expect(steps.last == Demo.Step(.inserted, key: .return))
            let tabs = steps.dropFirst(2).dropLast()
            #expect(tabs.count == c.picked + 1)
            #expect(tabs.allSatisfy { $0.key == .tab })
            #expect(tabs.last?.phase == .replies(highlighted: c.picked))
        }
    }

    @Test func tabPressesMatchTheRealPicker() {
        let c = Demo.script[2]
        var picker = ReplyPicker(replies: c.replies)
        for step in Demo.steps(c) where step.key == .tab {
            picker.next()
            #expect(step.phase == .replies(highlighted: picker.highlighted))
        }
        #expect(picker.chosen == c.replies[c.picked])
    }

    @Test func aPickOutOfRangeStillEnds() {
        let c = Demo.Conversation(sender: "A", message: "B", replies: ["x", "y"], picked: 5)
        let steps = Demo.steps(c)
        #expect(steps.count == 2 + 2 + 1)
        #expect(steps.last?.phase == .inserted)
    }
}
