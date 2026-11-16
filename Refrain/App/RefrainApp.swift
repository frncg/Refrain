import SwiftUI

/// No Dock icon or main window (`LSUIElement`): a menu bar player, and the lock screen overlay.
@main
struct RefrainApp: App {
    private let music: MusicController
    private let lockScreen: LockScreenController?

    init() {
        let music = MusicController()
        self.music = music

        // Previews run inside a copy of the app, which mustn't show a second overlay on lock.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            lockScreen = nil
        } else {
            music.start()
            lockScreen = LockScreenController(music: music)
            // As a test host, a prompt would appear mid-run and a dismissal would deny the real app.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                // Asked at launch: a prompt raised on the lock screen would be hidden.
                SystemAudioLevels.shared.requestPermission()
                LoginItem.registerOnce()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPlayer(music: music)
        } label: {
            Image(systemName: "music.note")
        }
        .menuBarExtraStyle(.window)
    }
}
