import AppKit
import HunchCore
import HunchSettingsStore
import SwiftUI

/// Where a settings search result goes, shared by the sidebar (which sets it) and the panes (which
/// scroll to it and highlight the row).
@MainActor @Observable
final class SettingsJump {
    static let shared = SettingsJump()

    /// The anchor to scroll to once its pane is showing; cleared when a pane takes it.
    var pending: String?
    /// Text a `hunch://settings?search=` link asked to type into the sidebar search; the
    /// Settings window takes it (and clears it) when it is open or opens.
    var requestedSearch: String?
    /// The anchor drawn highlighted right now.
    private(set) var highlighted: String?
    @ObservationIgnored private var fade: Task<Void, Never>?
    /// Where each anchored row is, in its window's SwiftUI coordinates (top-left origin). Kept out of
    /// observation: it changes on every scroll.
    @ObservationIgnored var frames: [String: CGRect] = [:]

    func flash(_ anchor: String) {
        fade?.cancel()
        withAnimation(.easeIn(duration: 0.15)) { highlighted = anchor }
        fade = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { self?.highlighted = nil }
        }
    }
}

extension View {
    /// Marks a row a search result can jump to; `id` is an anchor from `SettingsSearch`.
    /// For a whole section, put it on the section's header.
    func searchAnchor(_ id: String) -> some View { modifier(SearchAnchor(id: id)) }

    /// On a pane's Form: scrolls to the pending search anchor when it belongs to `pane`.
    /// `prepare` runs first, to open a closed group the row sits in.
    func searchScrollTarget(_ pane: String, prepare: @escaping (String) -> Void = { _ in }) -> some View {
        modifier(SearchScroll(pane: pane, prepare: prepare))
    }
}

private struct SearchAnchor: ViewModifier {
    let id: String

    func body(content: Content) -> some View {
        let on = SettingsJump.shared.highlighted == id
        content
            .id(id)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                SettingsJump.shared.frames[id] = frame
            }
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
                    .opacity(on ? 1 : 0)
                    .allowsHitTesting(false)
            }
    }
}

private struct SearchScroll: ViewModifier {
    let pane: String
    let prepare: (String) -> Void

    /// The window the pane is in, found by a zero-size AppKit view behind it.
    @State private var host = WindowBox()

    func body(content: Content) -> some View {
        content
            .background(WindowFinder(box: host))
            .onAppear { run() }
            .onChange(of: SettingsJump.shared.pending) { run() }
    }

    private func run() {
        let jump = SettingsJump.shared
        guard let anchor = jump.pending, SettingsSearch.pane(of: anchor) == pane else { return }
        jump.pending = nil
        prepare(anchor)
        // Give a pane that just appeared (or a group that just opened) a moment to lay out its rows.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if let window = host.window, let frame = jump.frames[anchor] {
                Self.center(frame, in: window)
            }
            jump.flash(anchor)
        }
    }

    /// Scrolls the scroll view under `frame` (SwiftUI window coordinates) so the frame is centered.
    /// `ScrollViewReader.scrollTo` does nothing in these grouped Forms, so this goes through AppKit.
    static func center(_ frame: CGRect, in window: NSWindow) {
        guard let root = window.contentView else { return }
        // SwiftUI's global space has its origin at the top-left of the window's content.
        let mid = NSPoint(x: frame.midX, y: root.isFlipped ? frame.midY : root.bounds.height - frame.midY)
        let inWindow = root.convert(mid, to: nil)
        guard let scroll = scrollViews(in: root).first(where: { sv in
                  sv.convert(sv.bounds, to: nil).insetBy(dx: 0, dy: -100_000).contains(inWindow)
                      && (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height
              }),
              let doc = scroll.documentView else { return }
        let clip = scroll.contentView
        let p = doc.convert(inWindow, from: nil)
        let height = clip.bounds.height
        let maxY = max(0, doc.frame.height - height)
        let y = min(max(0, (doc.isFlipped ? p.y : doc.frame.height - p.y) - height / 2), maxY)
        let target = NSPoint(x: clip.bounds.origin.x, y: doc.isFlipped ? y : maxY - y)
        // SwiftUI's clip view ignores AppKit animation, so ease it by hand over about a quarter second.
        let start = clip.bounds.origin.y
        Task { @MainActor in
            let steps = 15
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                clip.scroll(to: NSPoint(x: target.x, y: start + (target.y - start) * eased))
                scroll.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews(in:))
    }
}

/// Holds the window a `WindowFinder` found (a class, so setting it doesn't redraw the view).
@MainActor private final class WindowBox {
    weak var window: NSWindow?
}

private struct WindowFinder: NSViewRepresentable {
    let box: WindowBox

    func makeNSView(context: Context) -> NSView {
        let view = FinderView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class FinderView: NSView {
        var box: WindowBox?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            box?.window = window
        }
    }
}

// MARK: Results

/// One row under a pane in the searching sidebar.
struct SettingsSearchResult: Identifiable, Hashable {
    enum Target: Hashable {
        /// A row in a pane (its anchor).
        case anchor(String)
        /// An app, site or category in Apps & Sites, optionally at one of its settings.
        case place(PolicyKey, anchor: String?)
    }

    let id: String
    let pane: String
    let title: String
    let detail: String?
    let target: Target
}

@MainActor
enum SettingsSearchResults {
    /// Most places and per-place settings shown, so a broad query doesn't list hundreds of apps.
    static let placeLimit = 12
    static let overrideLimit = 30

    static func find(_ query: String, settings: HunchSettings, apps: AppsModel,
                     paneTitles: [String: String]) -> [SettingsSearchResult] {
        var results: [SettingsSearchResult] = SettingsSearch.search(query, paneTitles: paneTitles).map { e in
            if let req = e.requires, !req.isMet(settings) {
                return SettingsSearchResult(id: e.anchor, pane: e.pane, title: e.title,
                                            detail: "Turn on \(req.gate.name) to see it",
                                            target: .anchor(req.gate.anchor))
            }
            return SettingsSearchResult(id: e.anchor, pane: e.pane, title: e.title, detail: e.section,
                                        target: .anchor(e.anchor))
        }

        let keys = apps.apps.map { PolicyKey.app(bundleID: $0.bundleID) } + apps.sites
            + apps.categoryNames.map { PolicyKey.category(name: $0) }

        // Apps, sites and categories by name.
        let places = keys.compactMap { key -> (PolicyKey, Int)? in
            var extra: [String] = []
            if case .app(let id) = key { extra.append(id) }
            return SettingsSearch.score(query, title: apps.title(key), keywords: extra).map { (key, $0) }
        }
        .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : apps.title($0.0) < apps.title($1.0) }
        .prefix(placeLimit)
        results += places.map { key, _ in
            SettingsSearchResult(id: "place:\(key)", pane: "apps", title: apps.title(key),
                                 detail: kind(key), target: .place(key, anchor: nil))
        }

        // Settings an app, site or category changed from Default.
        var overrides: [(SettingsSearchResult, Int)] = []
        for setting in SettingsSearch.placeSettings {
            guard let score = SettingsSearch.score(query, title: setting.title, keywords: setting.keywords) else { continue }
            for key in keys where apps.hasPatch(key) && setting.isSet(apps.patch(key)) {
                overrides.append((SettingsSearchResult(
                    id: "override:\(key):\(setting.anchor)", pane: "apps", title: setting.title,
                    detail: "\(apps.title(key)) \u{00B7} changed", target: .place(key, anchor: setting.anchor)), score))
            }
        }
        results += overrides.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : ($0.0.detail ?? "") < ($1.0.detail ?? "") }
            .prefix(overrideLimit).map(\.0)
        return results
    }

    private static func kind(_ key: PolicyKey) -> String {
        switch key {
        case .app: "App"
        case .domain: "Website"
        case .category: "Category"
        }
    }
}

/// A result row: the title, and its section or where it comes from in grey.
struct SettingsSearchResultRow: View {
    let result: SettingsSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(result.title).lineLimit(1)
            if let detail = result.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.leading, 30)
    }
}

