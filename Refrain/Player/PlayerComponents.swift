import SwiftUI

extension EnvironmentValues {
    /// White on the lock screen; `.primary` in the menu bar, which follows the system appearance.
    @Entry var playerTint: Color = .white
}

struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    @Environment(\.playerTint) private var tint

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(tint.opacity(0.1))
                    .overlay {
                        GeometryReader { geometry in
                            Image(systemName: "music.note")
                                .font(.system(size: geometry.size.width * 0.35))
                                .foregroundStyle(tint.opacity(0.4))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .transition(.opacity)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

struct TrackInfoView: View {
    let music: MusicController
    let titleFont: Font
    var artistFont: Font = .body

    @Environment(\.playerTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.title ?? "Not Playing")
                .font(titleFont)
            Text(music.artist ?? "")
                .font(artistFont)
                .foregroundStyle(tint.opacity(0.6))
        }
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// Previous, play/pause and next, centred between `leading` and `trailing` buttons.
struct ControlsView<Leading: View, Trailing: View>: View {
    let music: MusicController
    let size: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(maxWidth: .infinity, alignment: .leading)
            transport
            trailing
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var transport: some View {
        HStack(spacing: 28) {
            button("backward.fill", action: music.previousTrack)
                .font(.system(size: size))
            button(music.isPlaying ? "pause.fill" : "play.fill", action: music.togglePlayPause)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: size * 1.5))
            button("forward.fill", action: music.nextTrack)
                .font(.system(size: size))
        }
    }

    private func button(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.plain)
    }
}

struct KaraokeToggle: View {
    let music: MusicController
    let size: CGFloat

    private let karaoke = Karaoke.shared

    var body: some View {
        CircleToggle(systemName: "music.microphone", isOn: karaoke.isOn, size: size) {
            karaoke.toggle(source: music.bundleIdentifier)
        }
        .disabled(!music.isMusicSource)
    }
}

struct LyricsButton {
    var isOn: Bool
    var action: () -> Void
}

struct LyricsToggle: View {
    let button: LyricsButton
    let hasLyrics: Bool
    let size: CGFloat

    var body: some View {
        CircleToggle(systemName: "quote.bubble", isOn: button.isOn && hasLyrics, size: size, action: button.action)
            .disabled(!hasLyrics)
    }
}

struct CircleToggle: View {
    let systemName: String
    let isOn: Bool
    let size: CGFloat
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.playerTint) private var tint

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.25))
                    .opacity(isOn ? 1 : 0)
                Image(systemName: systemName)
                    .font(.system(size: size * 0.6, weight: .medium))
                    .foregroundStyle(tint.opacity(isOn ? 1 : 0.55))
            }
            .frame(width: size * 1.2, height: size * 1.2)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: isOn)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
    }
}

/// Five bars of `SystemAudioLevels`, bass in the middle. Flat dots when paused.
struct PlaybackWaveform: View {
    let isPlaying: Bool
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 20

    @Environment(\.playerTint) private var tint
    private let audio = SystemAudioLevels.shared
    private static let bandOrder = [3, 1, 0, 2, 4]

    var body: some View {
        HStack(spacing: barWidth * 2 / 3) {
            ForEach(Self.bandOrder, id: \.self) { band in
                Capsule()
                    .frame(width: barWidth, height: height(band))
            }
        }
        .frame(height: maxHeight)
        .foregroundStyle(tint.opacity(isPlaying ? 0.9 : 0.5))
        .animation(.easeOut(duration: 0.08), value: audio.levels)
        .animation(.spring(duration: 0.4), value: isPlaying)
        .onAppear { audio.start() }
        .onDisappear { audio.stop() }
    }

    private func height(_ band: Int) -> CGFloat {
        let level = isPlaying ? CGFloat(audio.levels[band]) : 0
        return barWidth + (maxHeight - barWidth) * level
    }
}

@MainActor
func displayedElapsed(_ music: MusicController, scrub: Double?) -> TimeInterval {
    scrub.map { $0 * music.duration } ?? music.elapsed
}

func remainingTime(_ duration: TimeInterval, elapsed: TimeInterval) -> String {
    "-" + formatTime(max(duration - elapsed, 0))
}

func formatTime(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond))
}
