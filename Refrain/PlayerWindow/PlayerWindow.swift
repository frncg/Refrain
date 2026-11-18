import SwiftUI

/// The lock screen's full player in a regular window, which the green traffic light can make full screen.
/// Wide, it's `NowPlayingView` sized by `metrics(for:)`; tall (or too narrow for lyrics beside the
/// player), it morphs to `VerticalPlayer`. The traffic lights show while the pointer is over it.
struct PlayerWindow: View {
    static let id = "player"

    let music: MusicController

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var expanded = true
    @State private var hovering = false
    @State private var resizing = false
    @Namespace private var namespace

    /// The player column's height besides its artwork: track info, progress and controls.
    private static let columnChrome: CGFloat = 180
    /// The controls' width; the player column never gets narrower.
    private static let minColumn: CGFloat = 250
    /// Narrower than this beside the player, the lyrics switch the window to the vertical layout.
    private static let minLyrics: CGFloat = 260
    /// The layout with lyrics at its largest: artwork, gap and lyrics widths, and the lyrics' text
    /// scale (1 is the lock screen's). Narrower windows shrink all of it together.
    private static let fullArtwork: CGFloat = 570
    private static let fullGap: CGFloat = 72
    private static let fullLyrics: CGFloat = 900
    private static let fullLyricsScale: CGFloat = 1.1
    private static let minGap: CGFloat = 32
    private static let minLyricsScale: CGFloat = 0.8

    /// Fills the window with margins that grow with it. With lyrics, the artwork, gap, lyrics and
    /// their text keep their proportions and shrink together as the window narrows; the height can
    /// shrink the artwork on its own. Without lyrics, the artwork is as large as fits.
    static func metrics(for size: CGSize) -> PlayerMetrics {
        let margin = min(max(min(size.width, size.height) * 0.06, 24), 80)
        let usable = size.width - margin * 2
        let artworkHeight = max(size.height - margin * 2 - columnChrome, 120)

        let scale = min(usable / (fullArtwork + fullGap + fullLyrics), 1)
        let gap = max(fullGap * scale, minGap)
        let artwork = min(fullArtwork * scale, artworkHeight)
        let column = max(artwork, minColumn)
        let lyrics = max(min(fullLyrics * scale, usable - gap - column), 0)
        let bigArtwork = min(artworkHeight, usable, fullArtwork)
        // Centred, so the lyrics end as far from the right edge as the artwork starts from the left.
        let padding = max(margin, (size.width - column - gap - lyrics) / 2)

        return PlayerMetrics(
            columnWidth: column,
            artworkWidth: artwork,
            bigColumnWidth: max(bigArtwork, minColumn),
            bigArtworkWidth: bigArtwork,
            spacing: gap,
            horizontalPadding: padding,
            verticalPadding: margin,
            bigVerticalPadding: margin,
            bigWhenLyricsHidden: true,
            lyricsStyle: .lockScreen.scaled(by: max(fullLyricsScale * scale, minLyricsScale))
        )
    }

    static func isVertical(_ size: CGSize) -> Bool {
        guard size.width >= size.height else { return true }
        let metrics = metrics(for: size)
        let lyrics = size.width - metrics.horizontalPadding * 2 - metrics.spacing - metrics.columnWidth
        return lyrics < minLyrics
    }

    /// `LyricsStyle.vertical` suits a 460pt wide window.
    private static func verticalLyricsScale(for size: CGSize) -> CGFloat {
        min(max(size.width / 460, 0.8), 1.3)
    }

    var body: some View {
        GeometryReader { geometry in
            let vertical = Self.isVertical(geometry.size)
            ZStack {
                BlurredArtworkBackground(music: music)
                    .ignoresSafeArea()
                if vertical {
                    VerticalPlayer(
                        music: music,
                        namespace: namespace,
                        lyricsStyle: .vertical.scaled(by: Self.verticalLyricsScale(for: geometry.size))
                    )
                } else {
                    NowPlayingView(
                        music: music,
                        expanded: $expanded,
                        metrics: Self.metrics(for: geometry.size),
                        sharedNamespace: namespace,
                        floatingArtwork: true
                    ) {
                        dismissWindow(id: Self.id)
                    }
                }
                // One artwork for every layout, so it moves between them instead of fading out and in.
                FloatingArtwork(music: music)
                    .matchedGeometryEffect(id: PlayerMatched.artwork, in: namespace, isSource: false)
                    .allowsHitTesting(false)
            }
            .animation(NowPlayingTransition().animation, value: vertical)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(minWidth: 360, minHeight: 520)
        .onHover { hovering = $0 }
        .background(TrafficLights(visible: hovering))
        .background(LiveResizeReader(isResizing: $resizing))
        .environment(\.isLiveResizing, resizing)
        // A Dock icon while open, so the window can be reached with Command-Tab and from Mission Control.
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Fades the window's traffic lights in only while the pointer is over the window. In full screen
/// they're left to macOS, which shows them with the menu bar.
private struct TrafficLights: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> TrafficLightsView { TrafficLightsView() }

    func updateNSView(_ view: TrafficLightsView, context: Context) {
        view.visible = visible
    }
}

final class TrafficLightsView: NSView {
    var visible = false {
        didSet { if visible != oldValue { apply(animated: true) } }
    }
    private var fullScreen = false
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        fullScreen = window.styleMask.contains(.fullScreen)
        let changes: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false),
        ]
        for (name, fullScreen) in changes {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.fullScreen = fullScreen
                    self?.apply(animated: false)
                }
            })
        }
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        guard let buttons = window?.standardWindowButton(.closeButton)?.superview else { return }
        let alpha: CGFloat = visible || fullScreen ? 1 : 0
        guard animated else {
            buttons.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            buttons.animator().alphaValue = alpha
        }
    }
}

/// Whether the user is dragging the window's edge.
private struct LiveResizeReader: NSViewRepresentable {
    @Binding var isResizing: Bool

    func makeNSView(context: Context) -> LiveResizeView {
        let view = LiveResizeView()
        view.onChange = { isResizing = $0 }
        return view
    }

    func updateNSView(_ view: LiveResizeView, context: Context) {
        view.onChange = { isResizing = $0 }
    }
}

final class LiveResizeView: NSView {
    var onChange: (Bool) -> Void = { _ in }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        onChange(true)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onChange(false)
    }
}

/// The window's single artwork, placed over whichever layout's slot is showing.
private struct FloatingArtwork: View {
    let music: MusicController

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let large = side > 120
            ArtworkView(image: music.artwork, cornerRadius: min(max(side * 0.037, 8), 12))
                .shadow(color: .black.opacity(large ? 0.4 : 0.3), radius: large ? 20 : 10, y: large ? 8 : 4)
                .scaleEffect(large && !music.isPlaying ? 0.85 : 1)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: music.isPlaying)
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

#if DEBUG
#Preview("Player window", traits: .fixedLayout(width: 1100, height: 680)) {
    @Previewable @State var music = MusicController.preview()
    PlayerWindow(music: music)
}
#endif
