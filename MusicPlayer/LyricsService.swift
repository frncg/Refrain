//
//  LyricsService.swift
//  MusicPlayer
//

import Foundation

/// Fetches lyrics from LRCLIB (https://lrclib.net).
struct LyricsService: Sendable {
    private static let baseURL = URL(string: "https://lrclib.net/api")!
    private static let userAgent = "MusicPlayer/1.0"
    /// LRCLIB's own matching tolerance for /api/get is ±2s; search is looser.
    private static let durationTolerance: TimeInterval = 5

    private struct Track: Decodable {
        let id: Int
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    func lyrics(title: String, artist: String, album: String?, duration: TimeInterval) async throws -> Lyrics {
        if let track = try await getExact(title: title, artist: artist, album: album, duration: duration) {
            return Self.lyrics(from: track)
        }

        let results = try await search(title: title, artist: artist)
        guard let best = Self.bestMatch(in: results, duration: duration) else {
            return .notFound
        }
        return Self.lyrics(from: best)
    }

    // MARK: - Requests

    /// GET /api/get. Returns nil on 404.
    private func getExact(title: String, artist: String, album: String?, duration: TimeInterval) async throws -> Track? {
        var query = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album, !album.isEmpty {
            query.append(URLQueryItem(name: "album_name", value: album))
        }
        if duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded()))))
        }

        let (data, status) = try await request("get", query: query)
        if status == 404 { return nil }
        return try JSONDecoder().decode(Track.self, from: data)
    }

    /// GET /api/search
    private func search(title: String, artist: String) async throws -> [Track] {
        let (data, _) = try await request("search", query: [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ])
        return try JSONDecoder().decode([Track].self, from: data)
    }

    private func request(_ endpoint: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: Self.baseURL.appending(path: endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        // LRCLIB answers 503 ("server is busy") under load, so retry a couple of times.
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(attempt))
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 503 { continue }
            guard (200..<300).contains(status) || status == 404 else {
                throw URLError(.badServerResponse)
            }
            return (data, status)
        }
        throw URLError(.badServerResponse)
    }

    // MARK: - Matching

    private static func bestMatch(in tracks: [Track], duration: TimeInterval) -> Track? {
        let candidates = tracks.filter { track in
            guard duration > 0, let trackDuration = track.duration else { return true }
            return abs(trackDuration - duration) <= durationTolerance
        }
        return candidates.first { $0.syncedLyrics?.isEmpty == false }
            ?? candidates.first { $0.plainLyrics?.isEmpty == false }
            ?? candidates.first { $0.instrumental == true }
    }

    private static func lyrics(from track: Track) -> Lyrics {
        if let synced = track.syncedLyrics {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = track.plainLyrics.map(LyricsCleaner.clean(plain:)),
           !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .plain(plain)
        }
        if track.instrumental == true {
            return .instrumental
        }
        return .notFound
    }
}
