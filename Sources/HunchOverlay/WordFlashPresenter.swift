import AppKit
import HunchCore

private final class FlashPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A brief highlight over a word Hunch just changed in the host's text (autocorrect catch-up
/// and automatic fixes), so the change doesn't go unnoticed. Drawn only where the host gave the
/// word's bounds; the caller skips it otherwise.
@MainActor
public final class WordFlashPresenter {
    private var panel: FlashPanel?
    private var fade: Task<Void, Never>?

    public static let duration: Duration = .milliseconds(700)

    public init() {}

    /// Highlights `rect` (global AppKit coordinates), then fades out.
    public func flash(_ rect: CGRect) {
        let frame = rect.insetBy(dx: -2, dy: -1).integral
        guard frame.width > 0, frame.height > 0 else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: false)
        panel.contentView?.layer?.cornerRadius = min(4, frame.height / 4)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        fade?.cancel()
        fade = Task { @MainActor [weak panel] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.45
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }

    public func hide() {
        fade?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> FlashPanel {
        let p = FlashPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
        view.layer?.borderWidth = 1
        p.contentView = view
        return p
    }
}
