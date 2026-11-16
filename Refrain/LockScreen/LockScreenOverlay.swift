import SwiftUI

/// Covers the lock screen and redraws its clock and login hint around the player,
/// since nothing can be drawn between loginwindow's wallpaper and its UI.
struct LockScreenOverlay: View {
    let music: MusicController
    @Bindable var state = LockScreenOverlayState()
    var user = LockScreenUser.current
    var onExit: () -> Void

    @AppStorage(LockScreenOverlayState.expandedKey) private var savedExpanded = true

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                // Removed rather than hidden while collapsed, so the full-screen blur stops rendering.
                if state.expanded {
                    Group {
                        BlurredArtworkBackground(music: music)
                        LockScreenChrome(size: geometry.size, user: user)
                    }
                    .transition(.opacity)
                }

                // Saves the user's choices, not the collapse while typing.
                NowPlayingView(music: music, expanded: Binding {
                    state.expanded
                } set: {
                    state.expanded = $0
                    savedExpanded = $0
                }, onExit: onExit)
                    .frame(width: min(geometry.size.width - 160, 1000))
                    .frame(maxHeight: .infinity)
                    .padding(.top, height * 0.30)
                    .padding(.bottom, height * 0.22)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
    }
}

@Observable
final class LockScreenOverlayState {
    static let expandedKey = "lockScreenExpanded"

    var expanded = UserDefaults.standard.object(forKey: expandedKey) as? Bool ?? true
}

#if DEBUG
#Preview("Live", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.live()
    LockScreenOverlay(music: music, onExit: {})
}

#Preview("Sample", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var state: LockScreenOverlayState = {
        let state = LockScreenOverlayState()
        state.expanded = true
        return state
    }()
    LockScreenOverlay(music: music, state: state, onExit: {})
}

#Preview("Collapsed", traits: .fixedLayout(width: 1800, height: 1169)) {
    @Previewable @State var music = MusicController.preview()
    @Previewable @State var state: LockScreenOverlayState = {
        let state = LockScreenOverlayState()
        state.expanded = false
        return state
    }()
    LockScreenOverlay(music: music, state: state, onExit: {})
        .background(.black)
}
#endif
