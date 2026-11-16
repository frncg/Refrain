//
//  MusicController.swift
//  MusicPlayer
//

import CryptoKit
import SwiftUI
import MediaRemoteAdapter

@MainActor
@Observable
final class MusicController {
    let mediaController = MediaController()

    private(set) var title: String? = nil
    private(set) var artist: String? = nil
    private(set) var album: String? = nil
    private(set) var duration: TimeInterval = 0
    private(set) var elapsed: TimeInterval = 0
    private(set) var artwork: NSImage? = nil
    /// The artwork's average colour.
    private(set) var artworkColor: Color? = nil
    private(set) var isPlaying = false
    private(set) var lyrics: Lyrics = .idle
    /// Changes whenever `lyrics` is replaced, so views can transition between
    /// two sets of lyrics of the same kind.
    private(set) var lyricsID = 0
    /// The playing app, e.g. "Spotify" or "Safari".
    private(set) var sourceName: String? = nil
    /// Whether that's a music app or music website (see `NowPlayingSource`).
    /// The lock screen and lyrics only activate for music.
    private(set) var isMusicSource = false

    var progress: Double {
        duration > 0 ? min(elapsed / duration, 1) : 0
    }

    /// How track changes, artwork and lyrics animate in.
    static let changeAnimation = Animation.smooth(duration: 0.6)

    @ObservationIgnored private var trackID: String?
    @ObservationIgnored private let artworkCache = ArtworkCache()
    /// The playing app's bundle identifier.
    @ObservationIgnored private(set) var bundleIdentifier: String?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    /// The base64 artwork of the last payload, hashed in place. Payloads repeat
    /// their artwork, so it's decoded only when this changes.
    @ObservationIgnored private var artworkFingerprint: SHA256.Digest?
    @ObservationIgnored private var lyricsCache: [String: Lyrics] = [:]
    /// Oldest first, to keep `lyricsCache` to `lyricsCacheLimit` tracks.
    @ObservationIgnored private var lyricsCacheOrder: [String] = []
    private static let lyricsCacheLimit = 100
    @ObservationIgnored private let lyricsService = LyricsService()

    init() {
        // MediaController delivers every callback on the main queue.
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            MainActor.assumeIsolated { self?.handle(trackInfo.payload) }
        }

        // Estimated by the adapter from the last reported position (ticks every 0.25s).
        mediaController.onPlaybackTimeUpdate = { [weak self] elapsedTime in
            MainActor.assumeIsolated { self?.elapsed = elapsedTime }
        }

        mediaController.onDecodingError = { error, _ in
            print("Failed to decode JSON: \(error)")
        }

        mediaController.onListenerTerminated = {
            print("MediaRemoteAdapter listener process was terminated.")
        }
    }

    func start() {
        mediaController.startListening()
    }

    // MARK: - Controls

    func togglePlayPause() {
        isPlaying.toggle()
        mediaController.togglePlayPause()
    }

    func nextTrack() {
        mediaController.nextTrack()
    }

    func previousTrack() {
        mediaController.previousTrack()
    }

    func seek(to seconds: TimeInterval) {
        mediaController.setTime(seconds: seconds)
    }

    // MARK: - Track updates

    private func handle(_ payload: TrackInfo.Payload) {
        // Everything a payload changes (a new track, its artwork) animates.
        withAnimation(Self.changeAnimation) { apply(payload) }
    }

    private func apply(_ payload: TrackInfo.Payload) {
        let isNewTrack = payload.uniqueIdentifier != trackID
        trackID = payload.uniqueIdentifier
        let isNewSource = payload.bundleIdentifier != nil && payload.bundleIdentifier != bundleIdentifier
        if let identifier = payload.bundleIdentifier {
            bundleIdentifier = identifier
        }
        if let name = payload.applicationName {
            sourceName = name
        }

        title = payload.title
        artist = payload.artist
        album = payload.album
        if let durationMicros = payload.durationMicros {
            duration = durationMicros / 1_000_000
        }
        if let playing = payload.isPlaying {
            isPlaying = playing
        }
        if var base64 = payload.artworkDataBase64 {
            let fingerprint = base64.withUTF8 { SHA256.hash(data: UnsafeRawBufferPointer($0)) }
            // A new track still files repeated artwork (an album's) under itself.
            if fingerprint != artworkFingerprint || isNewTrack, let data = Data(base64Encoded: base64) {
                artworkFingerprint = fingerprint
                let digest = Artwork.digest(of: data)
                if digest != currentArtwork?.digest, let new = Artwork(data: data, digest: digest) {
                    setArtwork(new)
                }
                if let currentArtwork {
                    artworkCache.store(currentArtwork, data: data, title: payload.title, artist: payload.artist, album: payload.album)
                }
            }
        } else if isNewTrack {
            // Shown at once if this track or its album played before. The
            // payload's own artwork replaces it if it turns out different.
            setArtwork(artworkCache.artwork(title: payload.title, artist: payload.artist, album: payload.album))
            artworkFingerprint = nil
        }

        if isNewTrack || isNewSource {
            checkSource()
        }
    }

    /// Behind `artwork`. Payloads often repeat the same artwork, and each
    /// decodes to a new image, so its digest is compared before replacing it.
    @ObservationIgnored private var currentArtwork: Artwork?

    private func setArtwork(_ new: Artwork?) {
        currentArtwork = new
        artwork = new?.image
        artworkColor = new?.color
    }

    private func cacheLyrics(_ lyrics: Lyrics, for key: String) {
        if lyricsCache.updateValue(lyrics, forKey: key) == nil {
            lyricsCacheOrder.append(key)
        }
        if lyricsCacheOrder.count > Self.lyricsCacheLimit {
            lyricsCache[lyricsCacheOrder.removeFirst()] = nil
        }
    }

    private func setLyrics(_ new: Lyrics) {
        guard new != lyrics else { return }
        withAnimation(Self.changeAnimation) {
            lyrics = new
            lyricsID += 1
        }
    }

    /// Re-checks whether the source is music, then loads lyrics only if it is.
    /// Browsers are checked asynchronously (they're asked for their tabs).
    private func checkSource() {
        sourceTask?.cancel()
        lyricsTask?.cancel()
        isMusicSource = false
        setLyrics(.idle)

        let key = trackID
        let bundleIdentifier = bundleIdentifier
        let title = title
        sourceTask = Task {
            let isMusic = await NowPlayingSource.isMusic(bundleIdentifier: bundleIdentifier, title: title)
            guard !Task.isCancelled, key == trackID else { return }
            isMusicSource = isMusic
            // Karaoke moves to the new app, or stops if it isn't music.
            Karaoke.shared.follow(source: isMusic ? bundleIdentifier : nil)
            if isMusic {
                loadLyrics()
            }
        }
    }

    private func loadLyrics() {
        lyricsTask?.cancel()

        guard let key = trackID, let title, let artist, !title.isEmpty else {
            setLyrics(.idle)
            return
        }
        if let cached = lyricsCache[key] {
            setLyrics(cached)
            return
        }

        setLyrics(.loading)
        lyricsTask = Task {
            // Give duration/album a moment to arrive before querying.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            let result: Lyrics
            do {
                result = try await lyricsService.lyrics(
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration
                )
            } catch {
                result = .failed
            }

            guard !Task.isCancelled else { return }
            setLyrics(result)
            if result != .failed {
                cacheLyrics(result, for: key)
            }
        }
    }
}

#if DEBUG
extension MusicController {
    /// The real now playing, for SwiftUI previews. Hold it in `@Previewable @State`
    /// so the preview doesn't start a new listener process on every update.
    static func live() -> MusicController {
        let music = MusicController()
        music.start()
        return music
    }

    /// Fixed sample state for previewing a specific state (e.g. no lyrics).
    /// Doesn't start the MediaRemote listener.
    static func preview(
        lyrics: Lyrics? = nil,
        elapsed: TimeInterval = 14,
        isPlaying: Bool = true
    ) -> MusicController {
        let music = MusicController()
        music.title = "Preview Song With a Longer Title"
        music.artist = "Preview Artist"
        music.album = "Preview Album"
        music.duration = 180
        music.elapsed = elapsed
        music.isPlaying = isPlaying
        music.sourceName = "Preview"
        music.isMusicSource = true
        music.setArtwork(Artwork(image: previewArtwork))
        music.lyrics = lyrics ?? .synced(LRCParser.parse("""
        [00:02.00] First line of the placeholder lyrics
        [00:06.00] Second line that runs a little longer than the first one
        [00:10.00] Third line
        [00:13.00] This is the line being sung right now
        [00:17.00]
        [00:20.00] A line after the instrumental break
        [00:24.00] Another line to fill the column
        [00:28.00] Last line
        """))
        return music
    }

    private static let previewArtwork = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        NSGradient(colors: [.systemPink, .systemPurple, .systemIndigo])?.draw(in: rect, angle: -45)
        return true
    }
}
#endif
