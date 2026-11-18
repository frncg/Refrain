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
    private(set) var artworkColor: Color? = nil
    private(set) var artworkLuminance: Artwork.Luminance? = nil
    private(set) var artworkShade: Color? = nil
    private(set) var artworkGlow: Color? = nil
    private(set) var isPlaying = false
    private(set) var lyrics: Lyrics = .idle
    /// Bumped whenever `lyrics` is replaced, so views can transition between lyrics of the same kind.
    private(set) var lyricsID = 0
    private(set) var sourceName: String? = nil
    private(set) var isMusicSource = false
    /// Where a scrub bar is being dragged, so the lyrics follow it before the seek.
    var scrubTime: TimeInterval?

    var progress: Double {
        duration > 0 ? min(elapsed / duration, 1) : 0
    }

    static let changeAnimation = Animation.smooth(duration: 0.6)

    @ObservationIgnored private var trackID: String?
    @ObservationIgnored private let artworkCache = ArtworkCache()
    @ObservationIgnored private(set) var bundleIdentifier: String?
    @ObservationIgnored private var sourceTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    /// Payloads repeat their artwork, so it's only decoded when this hash changes.
    @ObservationIgnored private var artworkFingerprint: SHA256.Digest?
    @ObservationIgnored private var lyricsCache: [String: Lyrics] = [:]
    @ObservationIgnored private var lyricsCacheOrder: [String] = []
    private static let lyricsCacheLimit = 100
    @ObservationIgnored private let lyricsService = LyricsService()

    init() {
        // MediaController delivers every callback on the main queue.
        mediaController.onTrackInfoReceived = { [weak self] trackInfo in
            MainActor.assumeIsolated { self?.handle(trackInfo.payload) }
        }

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
            // A new track still caches repeated artwork (an album's) under itself.
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
            setArtwork(artworkCache.artwork(title: payload.title, artist: payload.artist, album: payload.album))
            artworkFingerprint = nil
        }

        if isNewTrack || isNewSource {
            checkSource()
        }
    }

    @ObservationIgnored private var currentArtwork: Artwork?

    private func setArtwork(_ new: Artwork?) {
        currentArtwork = new
        artwork = new?.image
        artworkColor = new?.color
        artworkLuminance = new?.luminance
        artworkShade = new?.shade
        artworkGlow = new?.glow
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
            // Give duration and album a moment to arrive before querying.
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
    /// Hold in `@Previewable @State` so previews don't start a listener on every update.
    static func live() -> MusicController {
        let music = MusicController()
        music.start()
        return music
    }

    static func preview(
        lyrics: Lyrics? = nil,
        elapsed: TimeInterval = 14,
        isPlaying: Bool = true,
        artwork: NSImage? = nil
    ) -> MusicController {
        let music = MusicController()
        music.title = "Neon Afterglow"
        music.artist = "The Placeholders"
        music.album = "Sample Album"
        music.duration = 180
        music.elapsed = elapsed
        music.isPlaying = isPlaying
        music.sourceName = "Music"
        music.isMusicSource = true
        music.setArtwork(Artwork(image: artwork ?? previewArtwork))
        music.lyrics = lyrics ?? .synced(LRCParser.parse("""
        [00:02.00] City lights are fading into blue
        [00:06.00] Every street I drive leads back to you
        [00:10.00] Radio is playing something slow
        [00:13.00] Hold the moment, never let it go
        [00:17.00]
        [00:20.00] Neon afterglow, across the sky
        [00:24.00] We were only chasing the night
        [00:28.00] Neon afterglow, don't say goodbye
        """))
        return music
    }

    private static let previewArtwork = NSImage(size: NSSize(width: 600, height: 600), flipped: false) { rect in
        NSGradient(colors: [.systemIndigo, .systemPurple, .systemPink, .systemOrange])?.draw(in: rect, angle: -90)
        NSGradient(colors: [.systemYellow, .systemOrange])?.draw(in: NSBezierPath(ovalIn: NSRect(x: 180, y: 170, width: 240, height: 240)), angle: -90)
        NSColor.black.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 600, height: 200)).fill()
        NSColor.systemPink.withAlphaComponent(0.6).setFill()
        for index in 0..<6 {
            NSBezierPath(rect: NSRect(x: 0, y: 190 - CGFloat(index * index) * 6, width: 600, height: 3)).fill()
        }
        return true
    }
}
#endif
