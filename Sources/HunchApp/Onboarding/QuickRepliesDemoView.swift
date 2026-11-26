import HunchCore
import Observation
import SwiftUI

/// The Quick replies page's demo: a small chat where a message arrives, the empty box gets replies in
/// the chosen layout (drawn like `SuggestedRepliesBubble`), Tab moves the highlight and Return puts the
/// reply in the box. Takes no focus and no clicks. A change of layout restarts the conversation; with
/// Quick replies off the box stays empty; with Reduce Motion it shows a still frame.
struct QuickRepliesDemoView: View {
    let layout: SuggestedRepliesLayout
    let enabled: Bool
    /// Show a fixed frame (conversation index, phase) instead of running; for snapshots.
    var frozen: (conversation: Int, phase: QuickRepliesDemo.Phase)?

    @State private var runner = QuickRepliesDemoRunner()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let chatHeight: CGFloat = 172
    static let boxHeight: CGFloat = 34

    private struct RunKey: Equatable {
        let layout: SuggestedRepliesLayout
        let enabled: Bool
        let still: Bool
    }

    var body: some View {
        VStack(spacing: 8) {
            chat
                .frame(height: Self.chatHeight)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.2)))
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            keys
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: RunKey(layout: layout, enabled: enabled, still: reduceMotion || frozen != nil)) {
            if let frozen {
                runner.freeze(conversation: frozen.conversation, phase: enabled ? frozen.phase : .message)
            } else if !enabled {
                runner.freeze(conversation: runner.conversation, phase: .message)
            } else if reduceMotion {
                let c = QuickRepliesDemo.script[0]
                runner.freeze(conversation: 0, phase: .replies(highlighted: c.picked))
            } else {
                await runner.run()
            }
        }
    }

    private var conversation: QuickRepliesDemo.Conversation { QuickRepliesDemo.script[runner.conversation] }

    private var accessibilityText: String {
        let c = QuickRepliesDemo.script[0]
        guard enabled else { return "Quick replies is off, so the message box stays empty." }
        let replies = c.replies.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        return "Quick replies demo: \(c.sender) asks \u{201C}\(c.message)\u{201D} The empty message box offers "
            + "\(replies). Tab picks one, Return puts it in the box."
    }

    // MARK: Chat

    private var showsMessage: Bool { runner.phase != .empty }

    private var highlighted: Int? {
        if case .replies(let h) = runner.phase { return h }
        return nil
    }

    private var showsReplies: Bool {
        if case .replies = runner.phase { return true }
        return false
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsMessage {
                // Their message: a gray bubble on the left, as chat apps draw it.
                Text(conversation.message)
                    .font(.system(size: 14))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.15)))
                    .opacity(runner.fading ? 0 : 1)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
            Spacer(minLength: 0)
            messageBox
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(enabled ? 1 : 0.55)
        .overlay {
            if !enabled {
                Label("Quick replies is off, so the box stays empty.", systemImage: "pause.circle")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private var messageBox: some View {
        HStack(spacing: 0) {
            if runner.phase == .inserted {
                Text(conversation.replies[min(conversation.picked, conversation.replies.count - 1)])
                    .fixedSize()
                    .opacity(runner.fading ? 0 : 1)
                    .transition(.opacity)
            }
            Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 18).padding(.leading, 1)
            if showsReplies, layout == .inlineAtCaret {
                HStack(spacing: 6) {
                    ForEach(Array(conversation.replies.enumerated()), id: \.offset) { i, reply in
                        DemoReplyChip(text: reply, style: .outlined, highlighted: i == highlighted)
                    }
                }
                .padding(.leading, 4)
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 14))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: Self.boxHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))
        // The layouts that sit above the box: their bottom edge 6 pt over its top.
        .overlay(alignment: .bottomLeading) {
            if showsReplies, layout != .inlineAtCaret {
                above
                    .fixedSize()
                    .offset(y: -(Self.boxHeight + 6))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .bottomLeading)))
            }
        }
    }

    @ViewBuilder private var above: some View {
        switch layout {
        case .verticalStack:
            // One panel, its left edge 6 pt left of the caret.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(conversation.replies.enumerated()), id: \.offset) { i, reply in
                    Text(reply)
                        .font(.system(size: 13))
                        .foregroundStyle(i == highlighted ? Color.white : Color.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(width: 190, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(i == highlighted ? Color.accentColor.opacity(0.85) : Color.clear))
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .offset(x: 5)
        case .rowAboveField, .inlineAtCaret:
            // Chips side by side from the box's left edge.
            HStack(spacing: 6) {
                ForEach(Array(conversation.replies.enumerated()), id: \.offset) { i, reply in
                    DemoReplyChip(text: reply, style: .filled, highlighted: i == highlighted)
                }
            }
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
    }

    // MARK: Keys

    private var keys: some View {
        HStack(spacing: 6) {
            DemoKey(text: "Tab \u{21E5}", pressed: runner.pressed == .tab)
            Text("picks a reply,")
            DemoKey(text: "Return \u{21A9}", pressed: runner.pressed == .return)
            Text("puts it in the box. Nothing is sent.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.55)
    }
}

/// One reply as a one-line capsule, like the bubble's chips: filled (row above the box) or outlined in
/// ghost gray (inline); accent-filled when Tab picked it.
private struct DemoReplyChip: View {
    enum Style { case filled, outlined }
    let text: String
    let style: Style
    let highlighted: Bool

    private var fill: Color {
        if highlighted { return Color.accentColor.opacity(0.9) }
        return style == .filled ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .controlBackgroundColor)
    }

    private var stroke: Color {
        style == .filled ? Color(nsColor: .separatorColor) : Color(nsColor: .secondaryLabelColor).opacity(0.7)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style == .filled ? 11 : 9, style: .continuous)
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(highlighted ? Color.white : style == .filled ? Color.primary : Color.secondary)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, style == .filled ? 5 : 3)
            .background {
                ZStack {
                    shape.fill(fill)
                    if !highlighted { shape.strokeBorder(stroke, lineWidth: 1) }
                }
            }
    }
}

/// A key cap that lights up while the demo presses it (same look as the other demos').
private struct DemoKey: View {
    let text: String
    let pressed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(pressed ? 0.3 : 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor.opacity(0.5)))
            .scaleEffect(pressed ? 0.92 : 1)
    }
}

/// Plays the script. Cancelling its task (a change of layout, leaving the page) stops it at once; the
/// next run starts the same conversation over.
@MainActor
@Observable
final class QuickRepliesDemoRunner {
    private(set) var conversation = 0
    private(set) var phase: QuickRepliesDemo.Phase = .empty
    private(set) var pressed: QuickRepliesDemo.Key?
    /// The chat is fading out before the next conversation (cleared once it is invisible, so the caret
    /// doesn't jump while the text is still showing).
    private(set) var fading = false

    func run() async {
        pressed = nil
        fading = false
        phase = .empty
        do {
            while true {
                try await Task.sleep(for: .milliseconds(350))
                for step in QuickRepliesDemo.steps(QuickRepliesDemo.script[conversation]) {
                    try await play(step)
                }
                try await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeInOut(duration: 0.3)) { fading = true }
                try await Task.sleep(for: .milliseconds(350))
                phase = .empty
                fading = false
                try await Task.sleep(for: .milliseconds(100))
                conversation = (conversation + 1) % QuickRepliesDemo.script.count
            }
        } catch {
            pressed = nil
        }
    }

    private func play(_ step: QuickRepliesDemo.Step) async throws {
        if let key = step.key {
            withAnimation(.easeOut(duration: 0.1)) { pressed = key }
            try await Task.sleep(for: .milliseconds(180))
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            phase = step.phase
            pressed = nil
        }
        let hold: Duration = switch step.phase {
        case .empty, .inserted: .zero
        case .message: .milliseconds(900)
        case .replies(nil): .milliseconds(1300)
        case .replies: .milliseconds(800)
        }
        try await Task.sleep(for: hold)
    }

    func freeze(conversation: Int, phase: QuickRepliesDemo.Phase) {
        self.conversation = min(max(conversation, 0), QuickRepliesDemo.script.count - 1)
        self.phase = phase
        pressed = nil
        fading = false
    }
}
