import SwiftUI

/// A smaller miniplayer for the menu bar, on the menu's default background.
/// Turning lyrics on extends the window down with a lyrics pane.
struct MenuBarPlayer: View {
    let music: MusicController

    @State private var scrub: Double?
    /// The waveform only exists while the menu is open, so the audio tap stops when it closes.
    @State private var isVisible = false
    /// Not `@AppStorage`: toggling that didn't animate.
    @State private var lyricsVisible = UserDefaults.standard.bool(forKey: Self.lyricsVisibleKey)
    private static let lyricsVisibleKey = "menuBarLyricsVisible"
    /// Kept while the next track's lyrics load, so the window doesn't shrink and grow between tracks.
    @State private var trackHasLyrics = false

    private static let animation = Animation.spring(duration: 0.35, bounce: 0.1)

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ArtworkView(image: music.artwork, cornerRadius: 6)
                    .frame(width: 42, height: 42)
                TrackInfoView(music: music, titleFont: .subheadline.bold(), artistFont: .subheadline)
                Spacer(minLength: 0)
                if isVisible {
                    PlaybackWaveform(isPlaying: music.isPlaying, barWidth: 2.5, maxHeight: 16)
                }
            }

            HStack(spacing: 8) {
                Text(formatTime(elapsed))
                ScrubBar(music: music, scrub: $scrub, height: 5)
                Text(remainingTime(music.duration, elapsed: elapsed))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)

            ControlsView(music: music, size: 18) {
                HStack(spacing: 4) {
                    KaraokeToggle(music: music, size: 18)
                    LyricsToggle(
                        button: LyricsButton(isOn: lyricsVisible) {
                            withAnimation(Self.animation) { lyricsVisible.toggle() }
                        },
                        hasLyrics: trackHasLyrics,
                        size: 18
                    )
                }
            } trailing: {
                MoreMenu(music: music, size: 18)
            }

            if lyricsVisible && trackHasLyrics {
                LyricsColumn(music: music, style: .menuBar)
                    .frame(height: 260)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(width: 300)
        .environment(\.playerTint, .primary)
        .background(WindowVisibilityReader(isVisible: $isVisible))
        .onChange(of: lyricsVisible) { _, visible in
            UserDefaults.standard.set(visible, forKey: Self.lyricsVisibleKey)
        }
        .onAppear { updateTrackHasLyrics(animated: false) }
        .onChange(of: music.lyrics) { updateTrackHasLyrics(animated: true) }
    }

    private func updateTrackHasLyrics(animated: Bool) {
        let hasLyrics: Bool
        switch music.lyrics {
        case .synced, .plain: hasLyrics = true
        case .notFound, .failed, .instrumental: hasLyrics = false
        case .idle, .loading: return
        }
        guard hasLyrics != trackHasLyrics else { return }
        withAnimation(animated ? Self.animation : nil) { trackHasLyrics = hasLyrics }
    }
}

private struct MoreMenu: View {
    let music: MusicController
    let size: CGFloat

    var body: some View {
        Menu {
            Text(sourceLabel)
            Divider()
            Button("Quit Refrain") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: size * 0.6, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: size * 1.2, height: size * 1.2)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var sourceLabel: String {
        guard let source = music.sourceName else { return "Nothing playing" }
        return music.isMusicSource ? "Playing from \(source)" : "\(source) isn't shown on the lock screen"
    }
}

#if DEBUG
#Preview("Live") {
    @Previewable @State var music = MusicController.live()
    MenuBarPlayer(music: music)
}

#Preview("Sample") {
    @Previewable @State var music = MusicController.preview()
    MenuBarPlayer(music: music)
}
#endif
