//
//  NowPlayingView.swift
//  MusicPlayer
//

import SwiftUI

/// Now playing with synced lyrics, in the band between the lock screen's clock
/// and login UI (see `LockScreenOverlay`). Tapping the artwork (or typing)
/// collapses it into a glass miniplayer; tapping that expands it again, and
/// holding its artwork exits. The lyrics button hides the lyrics, centring the player; in the
/// miniplayer it expands to the full player with lyrics instead. A track
/// without lyrics gets the centred player with bigger artwork instead of an
/// empty lyrics pane, unless that's turned off (`enlargeArtworkKey`).
struct NowPlayingView: View {
    let music: MusicController
    @Binding var expanded: Bool
    var transition = NowPlayingTransition()
    var onExit: () -> Void

    @Namespace private var namespace
    /// Saved under `lyricsVisibleKey`. Not `@AppStorage`: toggling that didn't
    /// animate the lyrics in and out.
    @State private var lyricsVisible = UserDefaults.standard.object(forKey: Self.lyricsVisibleKey) as? Bool ?? true
    private static let lyricsVisibleKey = "lockScreenLyricsVisible"

    /// UserDefaults key for enlarging the artwork when a track has no lyrics.
    static let enlargeArtworkKey = "lockScreenEnlargeArtworkWithoutLyrics"
    @AppStorage(enlargeArtworkKey) private var enlargesArtwork = true
    /// Whether the track turned out to have lyrics. Kept while the next
    /// track's lyrics load, so the layout doesn't jump at every track change.
    @State private var trackHasLyrics = true

    /// The lyrics pane is open but there's nothing to show in it.
    private var showsBigArtwork: Bool {
        lyricsVisible && !trackHasLyrics && enlargesArtwork
    }

    var body: some View {
        ZStack {
            if expanded {
                HStack(spacing: 48) {
                    PlayerColumn(
                        music: music,
                        namespace: namespace,
                        lyricsButton: LyricsButton(isOn: lyricsVisible) {
                            withAnimation(transition.animation) { lyricsVisible.toggle() }
                        },
                        onCollapse: { setExpanded(false) }
                    )
                    .frame(width: showsBigArtwork ? 391 : 322)
                    if lyricsVisible && !showsBigArtwork {
                        LyricsColumn(music: music)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
                // The big artwork needs the band's full height to reach its width.
                .padding(.vertical, showsBigArtwork ? 0 : 32)
            } else {
                MiniPlayer(
                    music: music,
                    namespace: namespace,
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
        // Set as it appears without animating; the overlay fades in anyway.
        .onAppear { updateTrackHasLyrics(animated: false) }
        .onChange(of: music.lyrics) { updateTrackHasLyrics(animated: true) }
        .animation(transition.animation, value: enlargesArtwork)
    }

    private func updateTrackHasLyrics(animated: Bool) {
        let hasLyrics: Bool
        switch music.lyrics {
        case .synced, .plain: hasLyrics = true
        case .notFound, .failed, .instrumental: hasLyrics = false
        case .idle, .loading: return
        }
        guard hasLyrics != trackHasLyrics else { return }
        withAnimation(animated ? transition.animation : nil) { trackHasLyrics = hasLyrics }
    }

    private func setExpanded(_ value: Bool) {
        withAnimation(transition.animation) {
            expanded = value
        }
    }
}

/// Full-screen blurred artwork, under the redrawn lock screen UI. It pulses
/// very slightly on the beat (`SystemAudioLevels.pulse`): a touch brighter,
/// more saturated and less blurred on each hit.
struct BlurredArtworkBackground: View {
    let music: MusicController

    /// The artwork drawn, which can trail `music.artwork` (see `show`).
    @State private var shown: NSImage?
    /// Its average colour, under it: shows through the artwork's opacity and
    /// keeps the screen in the artwork's colours as it fades.
    @State private var shownColor: Color?
    /// Bumped per artwork, so each new one draws above the one it replaces.
    @State private var generation = 0
    @State private var clearTask: Task<Void, Never>?
    private static let crossfade = Animation.easeInOut(duration: 1)
    /// Some players send a new track before its artwork. Within this, the old
    /// artwork fades straight into the new one instead of through black.
    private static let artworkGrace: Duration = .seconds(1.5)

    private let audio = SystemAudioLevels.shared
    private static let blur: CGFloat = 50
    // How much a full-strength hit changes each, kept subtle.
    private static let pulseBlur: CGFloat = -5
    private static let pulseBrightness: Double = 0.01
    private static let pulseSaturation: Double = 0.3

    var body: some View {
        let pulse = music.isPlaying ? Double(audio.pulse) : 0
        (shownColor?.mix(with: .black, by: 0.4) ?? .black)
            .overlay {
                ZStack {
                    if let shown {
                        Image(nsImage: shown)
                            .resizable()
                            .scaledToFill()
                            .id(generation)
                            .zIndex(Double(generation))
                            // The new artwork fades in over the old, which stays
                            // until it's covered, so the crossfade doesn't dip.
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity.animation(.linear(duration: 0.01).delay(1))
                            ))
                    }
                }
                .blur(radius: Self.blur + Self.pulseBlur * pulse, opaque: true)
                .saturation(1.4 + Self.pulseSaturation * pulse)
                .brightness(Self.pulseBrightness * pulse)
                .opacity(0.8)
                .animation(.easeOut(duration: 0.2), value: pulse)
            }
            .clipped()
            .onChange(of: music.artwork, initial: true) { _, artwork in show(artwork) }
            .onAppear { audio.start() }
            .onDisappear { audio.stop() }
    }

    private func show(_ artwork: NSImage?) {
        clearTask?.cancel()
        guard let artwork else {
            clearTask = Task {
                try? await Task.sleep(for: Self.artworkGrace)
                guard !Task.isCancelled else { return }
                withAnimation(Self.crossfade) {
                    shown = nil
                    shownColor = nil
                }
            }
            return
        }
        guard artwork !== shown else { return }
        // Not animated on first appearance: the overlay fades in as a whole.
        withAnimation(shown == nil && generation == 0 ? nil : Self.crossfade) {
            generation += 1
            shown = artwork
            shownColor = music.artworkColor
        }
    }
}

/// The expand/collapse animation. Tune it live in the "Transition" preview.
/// The lock screen overlay's background and redrawn clock fade with it too.
struct NowPlayingTransition {
    var duration: Double = 0.5
    var bounce: Double = 0.15
    /// Below 1 slows the animation down, for inspecting it.
    var speed: Double = 1

    var animation: Animation {
        .spring(duration: duration, bounce: bounce).speed(speed)
    }
}

// Shared IDs so the artwork, track info, progress and controls move between
// the full player and the miniplayer instead of fading out and back in.
private enum Matched: Hashable {
    case artwork, info, progress, controls, current, duration
}

// MARK: - Player

/// The lyrics button's state and action, which differ between the layouts.
private struct LyricsButton {
    var isOn: Bool
    var action: () -> Void
}

private struct PlayerColumn: View {
    let music: MusicController
    let namespace: Namespace.ID
    let lyricsButton: LyricsButton
    var onCollapse: () -> Void

    @State private var scrub: Double?

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        // A narrow column so the lyrics get most of the width. The artwork
        // shrinks to whatever height the text and controls leave.
        VStack(alignment: .leading, spacing: 14) {
            ArtworkView(image: music.artwork, cornerRadius: 12)
                .matchedGeometryEffect(id: Matched.artwork, in: namespace)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                .scaleEffect(music.isPlaying ? 1 : 0.85)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: music.isPlaying)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCollapse)

            TrackInfoView(music: music, titleFont: .title3.bold())
                .matchedGeometryEffect(id: Matched.info, in: namespace, properties: .position)

            VStack(spacing: 0) {
                ScrubBar(music: music, scrub: $scrub)
                    .matchedGeometryEffect(id: Matched.progress, in: namespace)
                HStack {
                    Text(formatTime(elapsed))
                        .matchedGeometryEffect(id: Matched.current, in: namespace)
                    Spacer()
                    Text(remainingTime(music.duration, elapsed: elapsed))
                        .matchedGeometryEffect(id: Matched.duration, in: namespace)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }

            ControlsView(music: music, size: 26, lyricsButton: lyricsButton)
                .matchedGeometryEffect(id: Matched.controls, in: namespace, properties: .position)
        }
    }
}

/// Modelled on the iOS lock screen player.
private struct MiniPlayer: View {
    let music: MusicController
    let namespace: Namespace.ID
    let lyricsButton: LyricsButton
    var onExpand: () -> Void
    var onExit: () -> Void

    @State private var pressingArtwork = false
    @State private var scrub: Double?

    var body: some View {
        let elapsed = displayedElapsed(music, scrub: scrub)
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ArtworkView(image: music.artwork, cornerRadius: 8)
                    .matchedGeometryEffect(id: Matched.artwork, in: namespace)
                    .frame(width: 56, height: 56)
                    .scaleEffect(pressingArtwork ? 0.85 : 1)
                    .animation(.spring(duration: 0.3), value: pressingArtwork)
                    .onLongPressGesture(minimumDuration: 0.5, perform: onExit) { pressing in
                        pressingArtwork = pressing
                    }
                TrackInfoView(music: music, titleFont: .headline)
                    .matchedGeometryEffect(id: Matched.info, in: namespace, properties: .position)
                Spacer(minLength: 0)
                PlaybackWaveform(isPlaying: music.isPlaying)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onExpand)

            HStack(spacing: 10) {
                Text(formatTime(elapsed))
                    .matchedGeometryEffect(id: Matched.current, in: namespace)
                ScrubBar(music: music, scrub: $scrub)
                    .matchedGeometryEffect(id: Matched.progress, in: namespace)
                Text(remainingTime(music.duration, elapsed: elapsed))
                    .matchedGeometryEffect(id: Matched.duration, in: namespace)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))

            ControlsView(music: music, size: 28, lyricsButton: lyricsButton)
                .matchedGeometryEffect(id: Matched.controls, in: namespace, properties: .position)
        }
        .padding(18)
        .frame(width: 440)
        .glassEffect(.clear, in: .rect(cornerRadius: 28))
    }
}

/// Five bars following the loudness of what's playing (`SystemAudioLevels`),
/// bass in the middle and treble at the edges. They lie flat as dots when
/// paused, or without the System Audio Recording permission.
private struct PlaybackWaveform: View {
    let isPlaying: Bool

    private let audio = SystemAudioLevels.shared
    /// Which band each bar shows, left to right.
    private static let bandOrder = [3, 1, 0, 2, 4]
    private static let barWidth: CGFloat = 3
    private static let maxHeight: CGFloat = 20

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.bandOrder, id: \.self) { band in
                Capsule()
                    .frame(width: Self.barWidth, height: height(band))
            }
        }
        .frame(height: Self.maxHeight)
        .foregroundStyle(.white.opacity(isPlaying ? 0.9 : 0.5))
        .animation(.easeOut(duration: 0.08), value: audio.levels)
        .animation(.spring(duration: 0.4), value: isPlaying)
        .onAppear { audio.start() }
        .onDisappear { audio.stop() }
    }

    /// Paused bars sit at their width, as dots.
    private func height(_ band: Int) -> CGFloat {
        let level = isPlaying ? CGFloat(audio.levels[band]) : 0
        return Self.barWidth + (Self.maxHeight - Self.barWidth) * level
    }
}

private struct ArtworkView: View {
    let image: NSImage?
    let cornerRadius: CGFloat

    var body: some View {
        // Crossfades: a new track's artwork (or the placeholder) fades in over
        // the old one, in the animation the change came with.
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .overlay {
                        GeometryReader { geometry in
                            Image(systemName: "music.note")
                                .font(.system(size: geometry.size.width * 0.35))
                                .foregroundStyle(.white.opacity(0.4))
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

private struct TrackInfoView: View {
    let music: MusicController
    let titleFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(music.title ?? "Not Playing")
                .font(titleFont)
            Text(music.artist ?? "")
                .font(.body)
                .foregroundStyle(.white.opacity(0.6))
        }
        .lineLimit(1)
        .contentTransition(.opacity)
    }
}

/// Karaoke, previous, play/pause, next and lyrics, spread across the width.
private struct ControlsView: View {
    let music: MusicController
    let size: CGFloat
    let lyricsButton: LyricsButton

    private let karaoke = Karaoke.shared

    var body: some View {
        HStack(spacing: 0) {
            CircleToggle(systemName: "music.microphone", isOn: karaoke.isOn, size: size) {
                karaoke.toggle(source: music.bundleIdentifier)
            }
            .disabled(!music.isMusicSource)
            Spacer(minLength: 12)
            HStack(spacing: 28) {
                button("backward.fill", action: music.previousTrack)
                    .font(.system(size: size))
                button(music.isPlaying ? "pause.fill" : "play.fill", action: music.togglePlayPause)
                    .contentTransition(.symbolEffect(.replace))
                    .font(.system(size: size * 1.5))
                button("forward.fill", action: music.nextTrack)
                    .font(.system(size: size))
            }
            Spacer(minLength: 12)
            // Off while there's nothing to show, even if the column is open.
            CircleToggle(systemName: "quote.bubble", isOn: lyricsButton.isOn && music.lyrics.hasText, size: size, action: lyricsButton.action)
                .disabled(!music.lyrics.hasText)
        }
        .frame(maxWidth: .infinity)
    }

    private func button(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.plain)
    }
}

/// An on/off button: a translucent symbol when off, and a white symbol on a
/// translucent white disc when on.
private struct CircleToggle: View {
    let systemName: String
    let isOn: Bool
    let size: CGFloat
    var action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.25))
                    .opacity(isOn ? 1 : 0)
                Image(systemName: systemName)
                    .font(.system(size: size * 0.6, weight: .medium))
                    .foregroundStyle(.white.opacity(isOn ? 1 : 0.55))
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

/// A progress bar that seeks. A press grabs it only near the playhead (the end
/// of the filled part), so stray presses elsewhere on it don't seek; dragging
/// then scrubs and the track jumps there on release. Like iOS, the bar grows
/// taller while held.
private struct ScrubBar: View {
    let music: MusicController
    /// The progress being dragged to, or nil when not scrubbing. Owned by the
    /// parent so its time labels follow the drag.
    @Binding var scrub: Double?

    @State private var startProgress: Double?
    /// Set for a press that started away from the playhead, until it ends.
    @State private var ignoringPress = false

    private static let height: CGFloat = 6
    /// How much the bar's width and height grow while held.
    static let pressedGrowth: CGFloat = 1.5
    static let pressAnimation = Animation.spring(duration: 0.3)
    /// How far from the playhead, either side, a press still grabs it.
    private static let grabDistance: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let growth = scrub != nil ? Self.pressedGrowth : 1
            Capsule()
                .fill(.white.opacity(0.2))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.white)
                        .frame(width: geometry.size.width * (scrub ?? music.progress))
                }
                .clipShape(Capsule())
                .frame(height: Self.height * growth)
                // Centred, so it grows out on both sides past its slot.
                .frame(width: geometry.size.width, height: geometry.size.height)
                // The visible bar is thin; the whole row takes the press.
                .contentShape(Rectangle())
                .gesture(drag(width: geometry.size.width))
        }
        .frame(height: 20)
        .animation(Self.pressAnimation, value: scrub != nil)
        .allowsHitTesting(music.duration > 0)
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !ignoringPress else { return }
                if startProgress == nil {
                    guard abs(value.startLocation.x - width * music.progress) <= Self.grabDistance else {
                        ignoringPress = true
                        return
                    }
                    startProgress = music.progress
                }
                guard let startProgress else { return }
                scrub = min(max(startProgress + value.translation.width / max(width, 1), 0), 1)
            }
            .onEnded { _ in
                ignoringPress = false
                // `setTime` updates elapsed right away, so clearing the scrub
                // doesn't snap the bar back first.
                if let scrub, scrub != startProgress {
                    music.seek(to: scrub * music.duration)
                }
                scrub = nil
                startProgress = nil
            }
    }
}

/// Elapsed time to show: the scrub position while dragging.
@MainActor
private func displayedElapsed(_ music: MusicController, scrub: Double?) -> TimeInterval {
    scrub.map { $0 * music.duration } ?? music.elapsed
}

private func remainingTime(_ duration: TimeInterval, elapsed: TimeInterval) -> String {
    "-" + formatTime(max(duration - elapsed, 0))
}

func formatTime(_ seconds: TimeInterval) -> String {
    Duration.seconds(max(seconds, 0)).formatted(.time(pattern: .minuteSecond))
}

// MARK: - Lyrics

private struct LyricsColumn: View {
    let music: MusicController

    private let karaoke = Karaoke.shared

    var body: some View {
        // A new state or a new song's lyrics fade in over the old.
        ZStack {
            content
                .id(music.lyricsID)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch music.lyrics {
        case .synced(let lines):
            SyncedLyricsView(
                lines: lines,
                // Karaoke audio trails the original, and the lyrics follow it.
                activeIndex: LRCParser.activeIndex(in: lines, at: music.elapsed - karaoke.delay),
                onSeek: music.seek
            )
        case .plain(let text):
            ScrollView(showsIndicators: false) {
                Text(text)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 40)
            }
        case .loading:
            ProgressView()
        case .instrumental:
            message("Instrumental")
        case .notFound:
            message("No lyrics found")
        case .failed:
            message("Couldn't load lyrics")
        case .idle:
            // Not EmptyView: that drops out of layout and collapses the panel.
            Color.clear
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.title2.bold())
            .foregroundStyle(.white.opacity(0.4))
    }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let activeIndex: Int?
    var onSeek: (TimeInterval) -> Void

    /// The line under the pointer, shown white like the active one, since
    /// tapping it seeks there.
    @State private var hoveredID: Int?

    /// Where the active line sits: a little above centre, leaving more room
    /// for upcoming lines. 0 is the top of the column, 1 the bottom.
    private static let activeLineAnchor = UnitPoint(x: 0.5, y: 0.3)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(lines) { line in
                        let isActive = line.id == activeIndex
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white.opacity(isActive || line.id == hoveredID ? 1 : 0.3))
                            .scaleEffect(isActive ? 1 : 0.8, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSeek(line.time) }
                            .onHover { hovering in
                                if hovering {
                                    hoveredID = line.id
                                } else if hoveredID == line.id {
                                    hoveredID = nil
                                }
                            }
                            .id(line.id)
                    }
                }
                .animation(.interpolatingSpring(.smooth), value: activeIndex)
                .animation(.easeOut(duration: 0.15), value: hoveredID)
                .padding(.vertical, 300)
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.15),
                        .init(color: .black, location: 0.85),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .onAppear {
                proxy.scrollTo(activeIndex ?? 0, anchor: Self.activeLineAnchor)
            }
            .onChange(of: activeIndex) { _, newIndex in
                withAnimation(.easeInOut(duration: 0.5)) {
                    proxy.scrollTo(newIndex ?? 0, anchor: Self.activeLineAnchor)
                }
            }
            .onChange(of: lines) {
                proxy.scrollTo(activeIndex ?? 0, anchor: Self.activeLineAnchor)
            }
        }
    }
}

#if DEBUG
// Sized like the band on a 1800×1169pt lock screen (see LockScreenOverlay).
// These show and control whatever is really playing.
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

// Sample data: synced lyrics, with the lyrics toggle on.
#Preview("Sample", traits: .fixedLayout(width: 1000, height: 561)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var expanded = true
    NowPlayingView(music: music, expanded: $expanded, onExit: {})
        .background { BlurredArtworkBackground(music: music) }
}

// Sample data: a state that can't be forced with what's really playing.
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
