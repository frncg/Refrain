//
//  ContentView.swift
//  MusicPlayer
//
//  Created by Franco Miguel Guevarra on 7/6/25.
//

import SwiftUI

struct ContentView: View {
    let music: MusicController
    var showLockScreen: () -> Void
    var hideLockScreen: () -> Void

    @AppStorage(NowPlayingView.enlargeArtworkKey) private var enlargeArtwork = true

    var body: some View {
        VStack {
            if let image = music.artwork {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 100, height: 100)
            }
            Text(music.title ?? "No Title")
                .font(.headline)
            Text(music.artist ?? "No Artist")
                .font(.subheadline)

            ProgressView(value: music.progress)

            if let source = music.sourceName {
                Text(music.isMusicSource ? "\(source): shows on lock screen" : "\(source): not a music source")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(action: music.togglePlayPause) {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }

            HStack {
                Button("Preview Lock Screen", action: showLockScreen)
                Button("Hide", action: hideLockScreen)
            }

            Toggle("Bigger artwork for songs without lyrics", isOn: $enlargeArtwork)
                .controlSize(.small)
        }
        .padding()
        .frame(width: 300, height: 330)
    }
}

#if DEBUG
#Preview {
    @Previewable @State var music = MusicController.live()
    ContentView(music: music, showLockScreen: {}, hideLockScreen: {})
}
#endif
