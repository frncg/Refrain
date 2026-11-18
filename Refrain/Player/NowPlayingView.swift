import SwiftUI

/// The lock screen player: a player column beside synced lyrics, or a glass miniplayer.
/// A track without lyrics gets a centred player with bigger artwork.
struct NowPlayingView: View {
    let music: MusicController
    @Binding var expanded: Bool
    var transition = NowPlayingTransition()
    var metrics = PlayerMetrics.lockScreen
    /// Lets another layout (the player window's vertical one) morph to and from this one.
    var sharedNamespace: Namespace.ID?
    /// Leaves an empty slot for an artwork drawn above (`ArtworkSlot`).
    var floatingArtwork = false
    var onExit: () -> Void

    @Namespace private var ownNamespace
    private var namespace: Namespace.ID { sharedNamespace ?? ownNamespace }
    /// Not `@AppStorage`: toggling that didn't animate.
    @State private var lyricsVisible = UserDefaults.standard.object(forKey: Self.lyricsVisibleKey) as? Bool ?? true
    static let lyricsVisibleKey = "lockScreenLyricsVisible"

    /// Kept while the next track's lyrics load, so the layout doesn't jump.
    @State private var trackHasLyrics = true
    /// Measured in `coordinateSpace`, to line the active lyric up with the artwork's centre.
    @State private var artworkMidY: CGFloat?
    @State private var lyricsFrame: CGRect?
    fileprivate static let coordinateSpace = "nowPlaying"

    private var lyricsFocus: CGFloat? {
        guard let artworkMidY, let lyricsFrame, lyricsFrame.height > 0 else { return nil }
        return min(max((artworkMidY - lyricsFrame.minY) / lyricsFrame.height, 0.1), 0.9)
    }

    private var showsBigArtwork: Bool {
        lyricsVisible ? !trackHasLyrics : metrics.bigWhenLyricsHidden
    }

    var body: some View {
        ZStack {
            if expanded {
                HStack(spacing: metrics.spacing) {
                    PlayerColumn(
                        music: music,
                        namespace: namespace,
                        floatingArtwork: floatingArtwork,
                        lyricsButton: LyricsButton(isOn: lyricsVisible) {
                            withAnimation(transition.animation) { lyricsVisible.toggle() }
                        },
                        artworkMaxWidth: showsBigArtwork ? metrics.bigArtworkWidth : metrics.artworkWidth,
                        onCollapse: { setExpanded(false) },
                        onArtworkMidY: { artworkMidY = $0 }
                    )
                    .frame(width: showsBigArtwork ? metrics.bigColumnWidth : metrics.columnWidth)
                    if lyricsVisible && !showsBigArtwork {
                        LyricsColumn(music: music, style: metrics.lyricsStyle, focus: lyricsFocus)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .matchedGeometryEffect(id: PlayerMatched.lyrics, in: namespace)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.coordinateSpace))
                            } action: { frame in
                                lyricsFrame = frame
                            }
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .coordinateSpace(.named(Self.coordinateSpace))
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, showsBigArtwork ? metrics.bigVerticalPadding : metrics.verticalPadding)
            } else {
                MiniPlayer(
                    music: music,
                    namespace: namespace,
                    floatingArtwork: floatingArtwork,
                    lyricsButton: LyricsButton(isOn: false) {
                        withAnimation(transition.animation) {
                            lyricsVisible = true
                            expanded = true
                        }
                    },
                    onExpand: { setExpanded(true) },
                    onExit: onExit
                )
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: lyricsVisible) { _, visible in
            UserDefaults.standard.set(visible, forKey: Self.lyricsVisibleKey)
        }
        .onAppear { updateTrackHasLyrics(animated: false) }
        .onChange(of: music.lyrics) { updateTrackHasLyrics(animated: true) }
    }

    private func updateTrackHasLyrics(animated: Bool) {
        guard let hasLyrics = music.lyrics.availability, hasLyrics != trackHasLyrics else { return }
        withAnimation(animated ? transition.animation : nil) { trackHasLyrics = hasLyrics }
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(transition.animation) {
            expanded = value
        }
    }
}

/// Sizes of the full player. The lock screen's were measured on a 1800×1169pt display;
/// the player window computes its own (`PlayerWindow.metrics(for:)`).
struct PlayerMetrics {
    var columnWidth: CGFloat = 322
    /// Narrower than the column when the height is short; nil fills the column.
    var artworkWidth: CGFloat?
    /// For a track without lyrics, centred with bigger artwork.
    var bigColumnWidth: CGFloat = 391
    var bigArtworkWidth: CGFloat?
    var spacing: CGFloat = 48
    var horizontalPadding: CGFloat = 32
    var verticalPadding: CGFloat = 32
    /// None on the lock screen, so the bigger artwork can reach its width in the band's height.
    var bigVerticalPadding: CGFloat = 0
    /// Whether turning lyrics off also gives the bigger artwork, rather than just centring the column.
    var bigWhenLyricsHidden = false
    var lyricsStyle = LyricsStyle.lockScreen

    static let lockScreen = PlayerMetrics()
}

/// Tune it in the "Transition" preview.
struct NowPlayingTransition {
    var duration: Double = 0.5
    var bounce: Double = 0.15
    var speed: Double = 1

    var animation: Animation {
        .spring(duration: duration, bounce: bounce).speed(speed)
    }
}

/// Views that `matchedGeometryEffect` moves between the player layouts.
enum PlayerMatched: Hashable {
    case artwork, info, progress, controls, current, duration, lyrics
}

private struct PlayerColumn: View {
    let music: MusicController
    let namespace: Namespace.ID
    let floatingArtwork: Bool
    let lyricsButton: LyricsButton
    var artworkMaxWidth: CGFloat?
    var onCollapse: () -> Void
    var onArtworkMidY: (CGFloat) -> Void

    @State private var scrub: Double?

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        VStack(alignment: .leading, spacing: 14) {
            ArtworkSlot(image: music.artwork, cornerRadius: 12, floating: floatingArtwork)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(NowPlayingView.coordinateSpace)).midY
                } action: { midY in
                    onArtworkMidY(midY)
                }
                .matchedGeometryEffect(id: PlayerMatched.artwork, in: namespace)
                .frame(maxWidth: artworkMaxWidth ?? .infinity)
                // Centred over the controls when it's narrower than them.
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .scaleEffect(music.isPlaying ? 1 : 0.85)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: music.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCollapse)

            TrackInfoView(music: music, titleFont: .title3.bold())
                .matchedGeometryEffect(id: PlayerMatched.info, in: namespace, properties: .position)

            VStack(spacing: 0) {
                ScrubBar(music: music, scrub: $scrub)
                    .matchedGeometryEffect(id: PlayerMatched.progress, in: namespace)
                HStack {
                    Text(formatTime(elapsed))
                        .matchedGeometryEffect(id: PlayerMatched.current, in: namespace)
                    Spacer()
                    Text(remainingTime(music.duration, elapsed: elapsed))
                        .matchedGeometryEffect(id: PlayerMatched.duration, in: namespace)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }

            ControlsView(music: music, size: 26) {
                KaraokeToggle(music: music, size: 26)
            } trailing: {
                LyricsToggle(button: lyricsButton, hasLyrics: music.lyrics.hasText, size: 26)
            }
                .matchedGeometryEffect(id: PlayerMatched.controls, in: namespace, properties: .position)
        }
    }
}

private struct MiniPlayer: View {
    let music: MusicController
    let namespace: Namespace.ID
    let floatingArtwork: Bool
    let lyricsButton: LyricsButton
    var onExpand: () -> Void
    var onExit: () -> Void

    @State private var pressingArtwork = false
    @State private var scrub: Double?

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ArtworkSlot(image: music.artwork, cornerRadius: 8, floating: floatingArtwork)
                    .matchedGeometryEffect(id: PlayerMatched.artwork, in: namespace)
                    .frame(width: 56, height: 56)
                    .scaleEffect(pressingArtwork ? 0.85 : 1)
                    .animation(.spring(duration: 0.3), value: pressingArtwork)
                    .onLongPressGesture(minimumDuration: 0.5, perform: onExit) { pressing in
                        pressingArtwork = pressing
                    }
                TrackInfoView(music: music, titleFont: .headline)
                    .matchedGeometryEffect(id: PlayerMatched.info, in: namespace, properties: .position)
                Spacer(minLength: 0)
                PlaybackWaveform(isPlaying: music.isPlaying)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)

            HStack(spacing: 10) {
                Text(formatTime(elapsed))
                    .matchedGeometryEffect(id: PlayerMatched.current, in: namespace)
                ScrubBar(music: music, scrub: $scrub)
                    .matchedGeometryEffect(id: PlayerMatched.progress, in: namespace)
                Text(remainingTime(music.duration, elapsed: elapsed))
                    .matchedGeometryEffect(id: PlayerMatched.duration, in: namespace)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))

            ControlsView(music: music, size: 28) {
                KaraokeToggle(music: music, size: 28)
            } trailing: {
                LyricsToggle(button: lyricsButton, hasLyrics: music.lyrics.hasText, size: 28)
            }
                .matchedGeometryEffect(id: PlayerMatched.controls, in: namespace, properties: .position)
        }
        .padding(18)
        .frame(width: 440)
        .glassEffect(.clear, in: .rect(cornerRadius: 28))
    }
}

#if DEBUG
// Sized like the band on a 1800×1169pt lock screen.
#Preview("Expanded", traits: .fixedLayout(width: 1000, height: 561)) {
    @Previewable @State var music = MusicController.live()
    @Previewable @State var expanded = true
    NowPlayingView(music: music, expanded: $expanded, onExit: {})
        .background { BlurredArtworkBackground(music: music) }
}

#Preview("Miniplayer", traits: .fixedLayout(width: 1000, height: 561)) {
    @Previewable @State var music = MusicController.live()
    @Previewable @State var expanded = false
    NowPlayingView(music: music, expanded: $expanded, onExit: {})
        .background { BlurredArtworkBackground(music: music) }
}

#Preview("Sample", traits: .fixedLayout(width: 1000, height: 561)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var expanded = true
    NowPlayingView(music: music, expanded: $expanded, onExit: {})
        .background { BlurredArtworkBackground(music: music) }
}

#Preview("No lyrics", traits: .fixedLayout(width: 1000, height: 561)) {
    @Previewable @State var music = MusicController.preview(lyrics: .notFound, isPlaying: false)
    @Previewable @State var expanded = true
    NowPlayingView(music: music, expanded: $expanded, onExit: {})
        .background { BlurredArtworkBackground(music: music) }
}

#Preview("Transition", traits: .fixedLayout(width: 1000, height: 681)) {
    @Previewable @State var music = MusicController.live()
    @Previewable @State var expanded = true
    @Previewable @State var transition = NowPlayingTransition()
    @Previewable @State var slowMotion = false

    let effective = NowPlayingTransition(
        duration: transition.duration,
        bounce: transition.bounce,
        speed: slowMotion ? 0.2 : 1
    )

    VStack(spacing: 0) {
        NowPlayingView(music: music, expanded: $expanded, transition: effective, onExit: {})
            .frame(height: 561)
            .background { BlurredArtworkBackground(music: music) }

        Form {
            HStack {
                Button(expanded ? "Collapse" : "Expand") {
                    withAnimation(effective.animation) { expanded.toggle() }
                }
                Toggle("Slow motion (5×)", isOn: $slowMotion)
                Spacer()
                Text(String(format: ".spring(duration: %.2f, bounce: %.2f)", transition.duration, transition.bounce))
                    .monospaced()
                    .textSelection(.enabled)
            }
            Slider(value: $transition.duration, in: 0.1...2) {
                Text("Duration")
            }
            Slider(value: $transition.bounce, in: -0.5...0.8) {
                Text("Bounce")
            }
        }
        .padding(12)
    }
}
#endif
