import Foundation
import Testing
@testable import Refrain

struct NowPlayingSourceTests {

    @Test func musicAppsCountAsMusic() async {
        #expect(await NowPlayingSource.isMusic(bundleIdentifier: "com.spotify.client", title: "Song"))
        #expect(await NowPlayingSource.isMusic(bundleIdentifier: "rocks.spotifast.Spotifast", title: "Song"))
        #expect(await NowPlayingSource.isMusic(bundleIdentifier: "dev.nolight.sonora", title: "Song"))
        #expect(await NowPlayingSource.isMusic(bundleIdentifier: "com.apple.Music", title: nil))
    }

    @Test func otherAppsDoNot() async {
        #expect(await !NowPlayingSource.isMusic(bundleIdentifier: "com.apple.QuickTimePlayerX", title: "Movie"))
        #expect(await !NowPlayingSource.isMusic(bundleIdentifier: "us.zoom.xos", title: "Meeting"))
        #expect(await !NowPlayingSource.isMusic(bundleIdentifier: nil, title: "Song"))
    }

    @Test func musicHostsIncludeSubdomains() {
        #expect(NowPlayingSource.isMusicHost(URL(string: "https://music.youtube.com/watch?v=x")))
        #expect(NowPlayingSource.isMusicHost(URL(string: "https://open.spotify.com/track/1")))
        #expect(NowPlayingSource.isMusicHost(URL(string: "https://artist.bandcamp.com/album/a")))
        #expect(NowPlayingSource.isMusicHost(URL(string: "https://www.deezer.com/us/")))
    }

    @Test func videoAndLookalikeHostsAreNotMusic() {
        #expect(!NowPlayingSource.isMusicHost(URL(string: "https://www.youtube.com/watch?v=x")))
        #expect(!NowPlayingSource.isMusicHost(URL(string: "https://notsoundcloud.com/")))
        #expect(!NowPlayingSource.isMusicHost(URL(string: "https://soundcloud.com.evil.example/")))
        #expect(!NowPlayingSource.isMusicHost(nil))
    }
}
