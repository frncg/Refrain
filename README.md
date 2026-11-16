# MusicPlayer

A now-playing screen for the macOS lock screen. When your Mac locks while music is playing, MusicPlayer covers the lock screen with the track's artwork, a player and synced lyrics, and redraws the clock and login prompt around them.

It doesn't play audio itself. It shows and controls whatever is already playing system-wide: Apple Music, Spotify, a browser tab on a music site, and so on.

## Features

- **Lock screen player** with blurred artwork background, playback controls and a scrubbable progress bar.
- **Synced lyrics** from [LRCLIB](https://lrclib.net). Tap a line to seek to it.
- **Miniplayer** that collapses out of the way when you start typing your password, and expands again when you stop.
- **Karaoke mode** that removes the vocals from the playing app, like Apple Music Sing.
- **Audio-reactive visuals**: a live waveform in the miniplayer, and a background that pulses with the drums.
- **Music only**: the lock screen player appears only for music apps and music websites, not for videos or podcasts in your browser.

Supported music apps: Apple Music, Spotify, Spotifast, TIDAL, Amazon Music, Deezer, YouTube Music Desktop, VOX, Doppler and Swinsian. In Safari and Chromium-based browsers, tabs on Apple Music, Spotify, YouTube Music, SoundCloud, TIDAL, Deezer, Amazon Music, Bandcamp, Pandora, Qobuz, Audiomack and Mixcloud count as music. Firefox isn't supported, because it can't report its tabs over AppleScript.

## Requirements

- macOS 26 or later
- Xcode 26 or later to build

## Building

```sh
git clone https://github.com/frncg/MusicPlayer.git
cd MusicPlayer
open MusicPlayer.xcodeproj
```

Then build and run the `MusicPlayer` scheme. Or from the command line:

```sh
xcodebuild -project MusicPlayer.xcodeproj -scheme MusicPlayer -destination 'platform=macOS' build
```

Out of the box the app is signed to run locally, which needs no Apple developer account. macOS ties permissions to the app's signature, though, so a locally signed build asks for them again after every rebuild. To sign with your own team instead, copy `Local.xcconfig.example` to `Local.xcconfig` and fill in your Team ID. `Local.xcconfig` is git-ignored.

## Permissions

| Permission | Why |
| --- | --- |
| **System Audio Recording** | Drives the waveform, the background pulse and karaoke mode. Audio is analysed live and never recorded or saved. Asked at launch, because a prompt raised on the lock screen would be hidden. |
| **Automation** (per browser) | Lets MusicPlayer read your browser's tab titles and URLs to tell whether it's playing music. Without it, browser playback is treated as not music. |

## How it works, and caveats

MusicPlayer relies on **private macOS APIs**, so it can't be sandboxed or distributed through the Mac App Store, and a future macOS update could break it:

- Now Playing information comes from the private MediaRemote framework, through [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter).
- Drawing above the lock screen uses private SkyLight APIs, through [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow).
- The System Audio Recording permission is checked and requested through private TCC functions, since there's no public API for it.

The overlay never draws a password field. It can't take keyboard focus, so everything you type goes straight to the real login window. MusicPlayer only notices *that* a key was pressed (to collapse into the miniplayer), never which key.

See [`CLAUDE.md`](CLAUDE.md) for a detailed tour of the architecture.

## Tests

```sh
xcodebuild -project MusicPlayer.xcodeproj -scheme MusicPlayer -destination 'platform=macOS' test -only-testing:MusicPlayerTests
```

## Acknowledgements

- [mediaremote-adapter](https://github.com/ejbills/mediaremote-adapter) by ejbills (BSD 3-Clause)
- [SkyLightWindow](https://github.com/Lakr233/SkyLightWindow) by Lakr233 (MIT)
- [LRCLIB](https://lrclib.net) for lyrics

## License

[MIT](LICENSE)
