import SwiftUI

/// Blurred artwork over its average colour, crossfading between songs and pulsing
/// subtly on the beat (`SystemAudioLevels.pulse`). Bright artwork is deepened just enough for white
/// text, with a saturated shade of its own colour rather than black; behind dark artwork the
/// background is lifted with a light shade of it instead, so the artwork stands out.
struct BlurredArtworkBackground: View {
    let music: MusicController

    @State private var shown: NSImage?
    @State private var shownColor: Color?
    @State private var scrim: Double = 0
    @State private var shade: Color = .black
    @State private var lift: Double = 0
    @State private var glow: Color = .black
    @State private var generation = 0
    @State private var clearTask: Task<Void, Never>?
    private static let crossfade = Animation.easeInOut(duration: 1)
    /// Some players send a new track before its artwork; within this, old fades straight into new.
    private static let artworkGrace: Duration = .seconds(1.5)

    private let audio = SystemAudioLevels.shared
    private static let blur: CGFloat = 50
    private static let pulseBlur: CGFloat = -5
    private static let pulseBrightness: Double = 0.01
    private static let pulseSaturation: Double = 0.3
    private static let artworkOpacity: Double = 0.8
    /// Extra saturation at full scrim, so deepened artwork stays vibrant.
    private static let scrimSaturation: Double = 0.5
    /// White text keeps at least this contrast against the brightest tenth of the background
    /// (WCAG AA for large text, which the lyrics are).
    static let textContrast: Double = 3

    /// The background's estimated luminance: blurred artwork over its average colour mixed 40%
    /// toward black (in sRGB, about a third in linear light).
    static func backgroundLuminance(for luminance: Artwork.Luminance) -> Double {
        artworkOpacity * luminance.bright + (1 - artworkOpacity) * luminance.average * 0.33
    }

    /// The opacity of `Artwork.shade` multiplied over the background that brings it down to
    /// `textContrast` against white. Multiplying by a colour of luminance s at opacity a scales
    /// luminance by 1 − a(1 − s).
    static func scrimOpacity(for luminance: Artwork.Luminance) -> Double {
        let background = backgroundLuminance(for: luminance)
        let target = 1.05 / textContrast - 0.05
        guard background > target else { return 0 }
        return min((1 - target / background) / (1 - luminance.shade), 1)
    }

    /// Behind dark artwork, the background's average aims for this contrast with the artwork's
    /// average (as a WCAG ratio), so the artwork's edges show.
    static let separation: Double = 2
    /// The lift never takes the background's average above this luminance, so it stays dark.
    private static let liftCeiling: Double = 0.12

    /// The opacity of `Artwork.glow` screened over the background to reach `separation`, as far as
    /// white text keeps `textContrast`. Screening a colour of luminance g at opacity a raises
    /// luminance L to about L + a·g(1 − L).
    static func liftOpacity(for luminance: Artwork.Luminance) -> Double {
        let textLimit = 1.05 / textContrast - 0.05
        let bright = backgroundLuminance(for: luminance)
        guard bright < textLimit, luminance.glow > 0 else { return 0 }
        let average = averageBackgroundLuminance(for: luminance)
        let target = min(separation * (luminance.average + 0.05) - 0.05, liftCeiling)
        guard average < target else { return 0 }
        let needed = (target - average) / (luminance.glow * (1 - average))
        let allowed = (textLimit - bright) / (luminance.glow * (1 - bright))
        return max(min(needed, allowed, 1), 0)
    }

    static func averageBackgroundLuminance(for luminance: Artwork.Luminance) -> Double {
        (artworkOpacity + (1 - artworkOpacity) * 0.33) * luminance.average
    }

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
                            // The old artwork stays until covered, so the crossfade doesn't dip.
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity.animation(.linear(duration: 0.01).delay(1))
                            ))
                    }
                }
                .blur(radius: Self.blur + Self.pulseBlur * pulse, opaque: true)
                .saturation(1.4 + Self.scrimSaturation * scrim + Self.pulseSaturation * pulse)
                .brightness(Self.pulseBrightness * pulse)
                .opacity(Self.artworkOpacity)
                .animation(.easeOut(duration: 0.2), value: pulse)
            }
            .overlay {
                Rectangle()
                    .fill(glow)
                    .opacity(lift)
                    .blendMode(.screen)
            }
            .overlay {
                Rectangle()
                    .fill(shade)
                    .opacity(scrim)
                    .blendMode(.multiply)
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
                    scrim = 0
                    lift = 0
                }
            }
            return
        }
        guard artwork !== shown else { return }
        withAnimation(shown == nil && generation == 0 ? nil : Self.crossfade) {
            generation += 1
            shown = artwork
            shownColor = music.artworkColor
            scrim = music.artworkLuminance.map(Self.scrimOpacity) ?? 0
            shade = music.artworkShade ?? .black
            lift = music.artworkLuminance.map(Self.liftOpacity) ?? 0
            glow = music.artworkGlow ?? .black
        }
    }
}
