import AppKit
import HunchCore

/// Plays the suggestions' pop-in effect on text that isn't a suggestion, one ghost per line or
/// streamed piece, each running the same effect as a suggestion would: dictated text at the caret
/// before it is pasted, and Write for me's draft as it streams.
@MainActor
public final class TextEffectPlayer {
    /// Settings → Appearance (an app's own look comes in the presentation's tweaks).
    public var appearance = AppearanceSettings()
    private weak var host: NSView?
    private var idle: [GhostOverlayPresenter] = []
    private var active: [ObjectIdentifier: GhostOverlayPresenter] = [:]
    /// Which showing each active ghost is on: ghosts are reused, so a timer from an earlier showing
    /// must not take down (or finish) a later one.
    private var showings: [ObjectIdentifier: Int] = [:]
    private var nextShowing = 0
    private var pending: [DispatchWorkItem] = []

    /// Floating ghosts on screen (dictation).
    public init() {}

    /// Ghosts drawn inside `host`, scrolling with it (Write for me's draft).
    public init(embeddedIn host: NSView) { self.host = host }

    /// The effect a presentation plays: the app's own look, else Appearance; a plain fade with
    /// Reduce Motion on. Empty for None.
    public func recipe(tweaks: GhostTweaks) -> PopInRecipe {
        PopIn.effective((tweaks.appearance ?? appearance).currentRecipe,
                        reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    public var isPlaying: Bool { !active.isEmpty || !pending.isEmpty }

    /// Plays `text` from the caret in `base`, wrapped like the field: the first line after the
    /// caret up to the field's right edge, the next ones from the line start, one caret height
    /// apart, none below the field. Returns the seconds until it has settled and the extra seconds
    /// particles stay in the air; (0, 0) when nothing plays (None, or nowhere to draw).
    public func playWrapped(_ text: String, base: GhostPresentation, color: NSColor?) -> (settle: TimeInterval, linger: TimeInterval) {
        let r = recipe(tweaks: base.tweaks)
        guard !r.isEmpty, text.contains(where: { !$0.isWhitespace }) else { return (0, 0) }
        let caret = base.geometry.caretRect
        let measurer = presenter()
        let (font, kern) = measurer.resolvedFont(for: base)
        recycle(measurer)
        let startX = OverlayLayout.inlineX(caretRect: caret)
        let field = base.geometry.fieldFrame.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil }
        let lineStart = base.geometry.lineStartX ?? field.map { $0.minX + 4 } ?? caret.minX
        // Hosts pad their text about as much on the right as on the left.
        let rightEdge = field.map { $0.maxX - max(2, lineStart - $0.minX) } ?? .greatestFiniteMagnitude
        let lines = EffectWrap.lines(text, firstWidth: rightEdge - startX, width: rightEdge - lineStart) {
            GhostOverlayPresenter.textWidth($0, font: font, kern: kern)
        }
        let advance = max(1, caret.height)
        var shown: [(text: String, caret: CGRect)] = []
        for (i, line) in lines.enumerated() {
            let rect = i == 0 ? caret
                : CGRect(x: lineStart - OverlayLayout.inlineXOffset, y: caret.minY - CGFloat(i) * advance,
                         width: 0, height: caret.height)
            if let field, i > 0, rect.minY < field.minY - 1 { break }
            shown.append((line, rect))
        }
        let counts = shown.map { $0.text.count }
        let delays = EffectWrap.lineDelays(r, counts: counts)
        for (line, delay) in zip(shown, delays) where !line.text.isEmpty {
            var p = base
            p.text = line.text
            p.mode = .inline
            p.geometry.caretRect = line.caret
            p.struckText = nil
            p.mirror = nil
            show(p, color: color, after: delay, hideAfter: nil)
        }
        return (EffectWrap.settleTime(r, counts: counts, delays: delays), EffectWrap.linger(r))
    }

    /// Plays one piece of text drawn at `presentation` (inline), starting `delay` seconds from now,
    /// then takes it down once settled (and its particles are done) and calls `done`. Returns the
    /// seconds from its start that takes, or nil (and plays nothing) for None.
    @discardableResult
    public func playPiece(_ presentation: GhostPresentation, color: NSColor?, after delay: TimeInterval = 0,
                          done: @escaping () -> Void) -> TimeInterval? {
        let r = recipe(tweaks: presentation.tweaks)
        guard !r.isEmpty, !presentation.text.isEmpty else { return nil }
        let seconds = PopIn.totalDuration(r, characters: presentation.text.count) + EffectWrap.linger(r)
        var p = presentation
        p.mode = .inline
        show(p, color: color, after: delay, hideAfter: seconds, done: done)
        return seconds
    }

    /// Takes every ghost down, at once or after `delay` seconds; pieces still waiting don't start.
    public func hideAll(after delay: TimeInterval = 0) {
        for item in pending { item.cancel() }
        pending = []
        guard delay > 0 else { takeAllDown(); return }
        let snapshot = showings
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, showing) in snapshot where self.showings[id] == showing {
                    if let p = self.active[id] { self.takeDown(p) }
                }
            }
        }
    }

    private func takeAllDown() {
        for p in Array(active.values) { takeDown(p) }
    }

    private func show(_ p: GhostPresentation, color: NSColor?, after delay: TimeInterval, hideAfter: TimeInterval?,
                      done: (() -> Void)? = nil) {
        let start = { [weak self] in
            guard let self else { return }
            let ghost = self.presenter()
            ghost.colorOverride = color
            let id = ObjectIdentifier(ghost)
            let showing = self.nextShowing
            self.nextShowing += 1
            self.active[id] = ghost
            self.showings[id] = showing
            ghost.present(p)
            guard let hideAfter else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter) { [weak self, weak ghost] in
                MainActor.assumeIsolated {
                    guard let self, let ghost, self.showings[ObjectIdentifier(ghost)] == showing else { return }
                    self.takeDown(ghost)
                    done?()
                }
            }
        }
        guard delay > 0 else { start(); return }
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pending.removeAll { $0 === item }
                start()
            }
        }
        pending.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func takeDown(_ ghost: GhostOverlayPresenter) {
        ghost.hide()
        active[ObjectIdentifier(ghost)] = nil
        showings[ObjectIdentifier(ghost)] = nil
        recycle(ghost)
    }

    private func presenter() -> GhostOverlayPresenter {
        let p = idle.popLast() ?? (host.map { GhostOverlayPresenter(embeddedIn: $0) } ?? GhostOverlayPresenter())
        p.appearance = appearance
        // A reused ghost would take new text that continues its old text as a redraw: start fresh.
        p.forgetShown()
        return p
    }

    private func recycle(_ p: GhostOverlayPresenter) {
        if idle.count < 12 { idle.append(p) }
    }
}
