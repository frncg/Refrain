import SwiftUI

/// A progress bar that seeks on release. A press only grabs it near the playhead,
/// and the bar grows while held.
struct ScrubBar: View {
    let music: MusicController
    /// Owned by the parent so its time labels follow the drag.
    @Binding var scrub: Double?
    var height: CGFloat = 6

    @State private var startProgress: Double?
    @State private var ignoringPress = false
    @Environment(\.playerTint) private var tint

    static let pressedGrowth: CGFloat = 1.5
    static let pressAnimation = Animation.spring(duration: 0.3)
    private static let grabDistance: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let growth = scrub != nil ? Self.pressedGrowth : 1
            Capsule()
                .fill(tint.opacity(0.2))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(tint)
                        .frame(width: geometry.size.width * (scrub ?? music.progress))
                }
                .clipShape(Capsule())
                .frame(height: height * growth)
                .frame(width: geometry.size.width, height: geometry.size.height)
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
                let progress = min(max(startProgress + value.translation.width / max(width, 1), 0), 1)
                scrub = progress
                music.scrubTime = progress * music.duration
            }
            .onEnded { _ in
                ignoringPress = false
                // `setTime` updates elapsed right away, so the bar doesn't snap back.
                if let scrub, scrub != startProgress {
                    music.seek(to: scrub * music.duration)
                }
                scrub = nil
                music.scrubTime = nil
                startProgress = nil
            }
    }
}
