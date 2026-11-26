import AVFoundation
import AppKit
import SwiftUI

// MARK: Intro video

/// The page after the model picks: a short silent video of what Hunch does, looping while the
/// models start downloading. Made by `scripts/intro-video/make.sh`; one file per appearance.
struct IntroVideoPage: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil until the page appears: playing, unless Reduce Motion is on (then a click starts it).
    @State private var playing: Bool?

    /// The video is 1280 x 800.
    private static let aspect: CGFloat = 1.6
    /// Where a paused video rests before it has played: a suggestion showing in the chat reply.
    private static let stillTime = 3.0

    static func videoURL(dark: Bool) -> URL? {
        Bundle.main.url(forResource: dark ? "intro-dark" : "intro-light", withExtension: "mp4")
    }

    var body: some View {
        if let url = Self.videoURL(dark: colorScheme == .dark) {
            VStack(spacing: 14) {
                Text("See Hunch in action")
                    .font(.title.weight(.semibold))
                video(url)
            }
        } else {
            // No video in this build (run outside the app bundle): say it in words.
            PageHeader(
                art: .appIcon, title: "See Hunch in action",
                message: "Hunch finishes your sentences as you type, polishes rough drafts and types what "
                    + "you say. The next pages set it up, then show each one.")
        }
    }

    private func video(_ url: URL) -> some View {
        let isPlaying = playing ?? !reduceMotion
        return IntroVideoPlayer(url: url, playing: isPlaying, stillTime: Self.stillTime)
            .aspectRatio(Self.aspect, contentMode: .fit)
            .frame(maxWidth: 584)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
            .overlay {
                if !isPlaying {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 54))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .shadow(radius: 8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { playing = !isPlaying }
            .onAppear { if playing == nil { playing = !reduceMotion } }
            .accessibilityElement()
            .accessibilityLabel("Intro video")
            .accessibilityValue("Hunch finishes a reply in a chat, shows suggestion effects, polishes a "
                + "rough email and types a dictated note. Everything runs on this Mac.")
            .accessibilityHint(isPlaying ? "Click to pause" : "Click to play")
            .accessibilityAddTraits(.isButton)
    }
}

/// A looping, silent player with no controls. It plays only while `playing` and its window is visible,
/// so a closed or covered tour window doesn't keep decoding video.
private struct IntroVideoPlayer: NSViewRepresentable {
    let url: URL
    let playing: Bool
    let stillTime: Double

    func makeNSView(context: Context) -> IntroPlayerView {
        let view = IntroPlayerView()
        view.stillTime = stillTime
        view.load(url)
        view.wantsPlaying = playing
        return view
    }

    func updateNSView(_ view: IntroPlayerView, context: Context) {
        view.load(url)
        view.wantsPlaying = playing
    }

    static func dismantleNSView(_ view: IntroPlayerView, coordinator: ()) {
        view.stop()
    }
}

final class IntroPlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var url: URL?
    private var occlusionObserver: (any NSObjectProtocol)?
    var stillTime = 0.0
    /// Whether it has played at all.
    private var started = false

    var wantsPlaying = false {
        didSet { refresh() }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Layer-hosting: the player layer is the view's own layer.
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        self.layer = layer
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Loads `url` unless it is already loaded (the appearance changed: the other file takes over).
    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        looper?.disableLooping()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        started = false
        refresh()
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    private func refresh() {
        guard looper != nil else { return }
        let visible = window?.occlusionState.contains(.visible) ?? false
        if wantsPlaying, visible {
            started = true
            player.play()
        } else {
            player.pause()
            // Paused before it ever played (Reduce Motion): rest on a frame that shows something.
            if !wantsPlaying, !started {
                player.seek(to: CMTime(seconds: stillTime, preferredTimescale: 600), toleranceBefore: .zero,
                            toleranceAfter: .zero)
            }
        }
    }
}
