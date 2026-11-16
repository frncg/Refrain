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
    /// Refreshed when the menu opens or the source changes; each check is a round trip to tccd.
    @State private var permissions = PermissionStatus()

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
                MoreMenu(music: music, permissions: permissions, size: 18, onPermissionChange: refreshPermissions)
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
        .onChange(of: isVisible) { _, visible in
            if visible { refreshPermissions() }
        }
        .onChange(of: music.sourceName) { refreshPermissions() }
    }

    private func refreshPermissions() {
        let source = music.bundleIdentifier
        permissions = PermissionStatus(
            audio: SystemAudioPermission.status,
            automation: NowPlayingSource.isBrowser(source) ? source.flatMap { AutomationPermission.status(for: $0) } : nil
        )
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

private struct PermissionStatus {
    var audio = SystemAudioPermission.Status.unknown
    /// Only for browsers, the one kind of source Refrain controls over Apple Events.
    var automation: AutomationPermission.Status?
}

private struct MoreMenu: View {
    let music: MusicController
    let permissions: PermissionStatus
    let size: CGFloat
    var onPermissionChange: () -> Void

    var body: some View {
        Menu {
            Text(sourceLabel)
            audioPermission
            if let automation = permissions.automation, let browser = music.sourceName {
                automationPermission(automation, browser: browser)
            }
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

    @ViewBuilder
    private var audioPermission: some View {
        switch permissions.audio {
        case .authorized:
            Text("System Audio Recording: Allowed")
        case .denied:
            Button("System Audio Recording: Off — Open Settings…", action: SystemAudioPermission.openSettings)
        case .unknown:
            Button("System Audio Recording: Not Asked — Allow…") {
                SystemAudioPermission.request { _ in
                    DispatchQueue.main.async(execute: onPermissionChange)
                }
            }
        }
    }

    @ViewBuilder
    private func automationPermission(_ status: AutomationPermission.Status, browser: String) -> some View {
        switch status {
        case .allowed:
            Text("\(browser) Automation: Allowed")
        case .denied:
            Button("\(browser) Automation: Off — Open Settings…", action: AutomationPermission.openSettings)
        case .notAsked:
            Text("\(browser) Automation: Not Asked")
        }
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
