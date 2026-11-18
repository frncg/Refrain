import SwiftUI

/// The player window's layout when it's taller than wide, like Music on iPhone: the track and
/// lyrics above the progress and controls, or big artwork when lyrics are off or missing.
/// Shares `namespace` with `NowPlayingView`, so the window morphs between the two.
struct VerticalPlayer: View {
    let music: MusicController
    let namespace: Namespace.ID
    var lyricsStyle = LyricsStyle.vertical
    /// The player window draws the artwork itself (`ArtworkSlot`).
    var floatingArtwork = true

    /// Shared with the lock screen's full player.
    @State private var lyricsVisible = UserDefaults.standard.object(forKey: NowPlayingView.lyricsVisibleKey) as? Bool ?? true
    /// Kept while the next track's lyrics load, so the layout doesn't jump.
    @State private var trackHasLyrics = true
    @State private var scrub: Double?

    private let animation = NowPlayingTransition().animation

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        VStack(spacing: 0) {
            ZStack {
                if lyricsVisible && trackHasLyrics {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 14) {
                            ArtworkSlot(image: music.artwork, cornerRadius: 8, floating: floatingArtwork)
                                .matchedGeometryEffect(id: PlayerMatched.artwork, in: namespace)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                            TrackInfoView(music: music, titleFont: .headline)
                                .matchedGeometryEffect(id: PlayerMatched.info, in: namespace, properties: .position)
                            Spacer(minLength: 0)
                        }
                        LyricsColumn(music: music, style: lyricsStyle, focus: 0.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .matchedGeometryEffect(id: PlayerMatched.lyrics, in: namespace)
                            .transition(.opacity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        ArtworkSlot(image: music.artwork, cornerRadius: 12, floating: floatingArtwork)
                            .matchedGeometryEffect(id: PlayerMatched.artwork, in: namespace)
                            .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                            .scaleEffect(music.isPlaying ? 1 : 0.85)
                            .animation(.spring(duration: 0.5, bounce: 0.3), value: music.isPlaying)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TrackInfoView(music: music, titleFont: .title2.bold(), artistFont: .title3)
                            .matchedGeometryEffect(id: PlayerMatched.info, in: namespace, properties: .position)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 20)

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

            ControlsView(music: music, size: 30) {
                KaraokeToggle(music: music, size: 30)
            } trailing: {
                LyricsToggle(
                    button: LyricsButton(isOn: lyricsVisible) {
                        withAnimation(animation) { lyricsVisible.toggle() }
                    },
                    hasLyrics: music.lyrics.hasText,
                    size: 30
                )
            }
            .matchedGeometryEffect(id: PlayerMatched.controls, in: namespace, properties: .position)
            .padding(.top, 20)
        }
        .padding(.horizontal, 32)
        .padding(.top, 8)
        .padding(.bottom, 32)
        .frame(maxWidth: 600)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .onChange(of: lyricsVisible) { _, visible in
            UserDefaults.standard.set(visible, forKey: NowPlayingView.lyricsVisibleKey)
        }
        .onAppear { updateTrackHasLyrics(animated: false) }
        .onChange(of: music.lyrics) { updateTrackHasLyrics(animated: true) }
    }

    private func updateTrackHasLyrics(animated: Bool) {
        guard let hasLyrics = music.lyrics.availability, hasLyrics != trackHasLyrics else { return }
        withAnimation(animated ? animation : nil) { trackHasLyrics = hasLyrics }
    }
}

#if DEBUG
#Preview("Vertical", traits: .fixedLayout(width: 460, height: 860)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @Namespace var namespace
    ZStack {
        BlurredArtworkBackground(music: music)
        VerticalPlayer(music: music, namespace: namespace, floatingArtwork: false)
    }
}
#endif
