//
//  MusicPlayerApp.swift
//  MusicPlayer
//
//  Created by Franco Miguel Guevarra on 7/6/25.
//

import SwiftUI

@main
struct MusicPlayerApp: App {
    @State private var music: MusicController
    private let lockScreen: LockScreenController?

    init() {
        let music = MusicController()
        _music = State(initialValue: music)

        // Xcode runs previews inside a copy of this app. Previews make their own
        // controller (`MusicController.live()`), and a second lock screen overlay
        // from the preview copy would show up when the Mac locks.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            lockScreen = nil
        } else {
            music.start()
            lockScreen = LockScreenController(music: music)
            // Asked now, at the desktop: the miniplayer's waveform needs it,
            // and a prompt raised while locked would be hidden.
            SystemAudioLevels.shared.requestPermission()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                music: music,
                showLockScreen: { lockScreen?.show() },
                hideLockScreen: { lockScreen?.hide() }
            )
        }
    }
}
