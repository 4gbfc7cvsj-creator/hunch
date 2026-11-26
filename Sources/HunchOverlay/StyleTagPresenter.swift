import AppKit
import HunchCore

private final class TagPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A small pill under the caret naming the suggestion style in use ("Casual"), shown with the ghost
/// while a style other than the app's own is on. Smaller grey chips on either side name the styles
/// the previous and next keys go to, so the order needn't be remembered. A style key slides the
/// chips like a carousel: forward, each chip arrives from its right-hand neighbour's place (the old
/// current one moves left into the previous slot) and the new next chip fades in from the edge;
/// back is the mirror image. Reduce Motion turns the slide into a fade.
@MainActor
public final class StyleTagPresenter {
    private struct Chip {
        let view: NSView
        let label: NSTextField
    }

    private var panel: TagPanel?
    private var chips: (previous: Chip, current: Chip, next: Chip)?

    private static let gap: CGFloat = 4
    /// Var so the visual check can slow it down enough to screenshot.
    static var slideDuration: CFTimeInterval = 0.22

    public init() {}

    /// Shows the tag just under `caret` (global AppKit coordinates), the current style's chip
    /// starting at the caret; nil hides it.
    public func show(_ names: StyleTagNames?, caret: CGRect?) {
        guard let names, let caret else { return hide() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let chips else { return }
        let previous = size(chips.previous, "\u{2190} " + names.previous, padding: 10)
        let current = size(chips.current, names.current, padding: 12)
        let next = size(chips.next, names.next + " \u{2192}", padding: 10)
        let height = current.height
        let width = previous.width + current.width + next.width + 2 * Self.gap

        var origin = CGPoint(x: caret.minX - previous.width - Self.gap, y: caret.minY - height - 3)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(caret.origin) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
        }
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)).integral, display: false)

        var x: CGFloat = 0
        var slots: [CGFloat] = []
        for (chip, size) in [(chips.previous, previous), (chips.current, current), (chips.next, next)] {
            chip.view.frame = CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            chip.label.frame = chip.view.bounds.insetBy(dx: (size.width - chip.label.frame.width) / 2,
                                                       dy: (size.height - chip.label.frame.height) / 2)
            chip.view.layer?.cornerRadius = size.height / 2
            slots.append(x)
            x += size.width + Self.gap
        }
        if let step = names.step { slide(step, chips: chips, slots: slots, width: width) }
        panel.orderFrontRegardless()
    }

    /// Plays the ring's move: each chip starts where its neighbour (the way the ring moved) sits now
    /// and settles into its own place; the chip coming into view fades in from past the edge.
    private func slide(_ step: StyleTagNames.Step, chips: (previous: Chip, current: Chip, next: Chip),
                       slots: [CGFloat], width: CGFloat) {
        let views = [chips.previous.view, chips.current.view, chips.next.view]
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Forward: previous comes from current's slot, current from next's, next from past the right edge.
        let starts: [CGFloat] = step == .forward
            ? [slots[1], slots[2], width + Self.gap]
            : [-views[0].frame.width - Self.gap, slots[0], slots[1]]
        let arriving = step == .forward ? 2 : 0
        for (i, view) in views.enumerated() {
            guard let layer = view.layer else { continue }
            layer.removeAllAnimations()
            let group = CAAnimationGroup()
            group.duration = Self.slideDuration
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = i == arriving ? 0 : (reduceMotion ? 0.4 : 0.7)
            fade.toValue = 1
            if reduceMotion {
                group.animations = [fade]
            } else {
                let move = CABasicAnimation(keyPath: "transform.translation.x")
                move.fromValue = starts[i] - slots[i]
                move.toValue = 0
                group.animations = [move, fade]
            }
            layer.add(group, forKey: "styleSlide")
        }
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func size(_ chip: Chip, _ text: String, padding: CGFloat) -> CGSize {
        chip.label.stringValue = text
        chip.label.sizeToFit()
        return CGSize(width: ceil(chip.label.frame.width) + padding, height: ceil(chip.label.frame.height) + 4)
    }

    private func makePanel() -> TagPanel {
        let p = TagPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let content = NSView()
        func chip(background: NSColor, font: NSFont, text: NSColor) -> Chip {
            let view = NSView()
            view.wantsLayer = true
            view.layer?.backgroundColor = background.cgColor
            let label = NSTextField(labelWithString: "")
            label.font = font
            label.textColor = text
            view.addSubview(label)
            content.addSubview(view)
            return Chip(view: view, label: label)
        }
        let side = { chip(background: NSColor.systemGray.withAlphaComponent(0.6),
                          font: .systemFont(ofSize: 9, weight: .medium), text: NSColor.white.withAlphaComponent(0.9)) }
        chips = (side(),
                 chip(background: NSColor.controlAccentColor.withAlphaComponent(0.85),
                      font: .systemFont(ofSize: 10, weight: .semibold), text: .white),
                 side())
        p.contentView = content
        return p
    }
}
