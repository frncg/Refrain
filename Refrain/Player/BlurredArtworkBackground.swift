import SwiftUI

/// Blurred artwork over its average colour, crossfading between songs and pulsing
/// subtly on the beat (`SystemAudioLevels.pulse`).
struct BlurredArtworkBackground: View {
    let music: MusicController

    @State private var shown: NSImage?
    @State private var shownColor: Color?
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
        withAnimation(shown == nil && generation == 0 ? nil : Self.crossfade) {
            generation += 1
            shown = artwork
            shownColor = music.artworkColor
        }
    }
}
