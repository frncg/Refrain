import AppKit

/// Artwork seen before, in memory and in ~/Library/Caches, filed under both the
/// track and its album so the artwork shows as soon as a track starts.
@MainActor
final class ArtworkCache {
    private nonisolated static let diskLimit = 300

    private let memory = NSCache<NSString, Artwork>()
    private let directory: URL
    private let disk = DispatchQueue(label: "ArtworkCache", qos: .utility)

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "Refrain")
            .appending(path: "Artwork")
        // About 9 MB, 3 to 6 covers. Evicted covers reload from disk in a millisecond or two.
        memory.totalCostLimit = 6 * Artwork.maxPixelSize * Artwork.maxPixelSize * 4
        let directory = self.directory
        disk.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.prune(directory)
        }
    }

    func artwork(title: String?, artist: String?, album: String?) -> Artwork? {
        for key in Self.keys(title: title, artist: artist, album: album) {
            if let artwork = memory.object(forKey: key as NSString) {
                return artwork
            }
            if let data = try? Data(contentsOf: file(key)), let artwork = Artwork(data: data) {
                memory.setObject(artwork, forKey: key as NSString, cost: artwork.cost)
                return artwork
            }
        }
        return nil
    }

    func store(_ artwork: Artwork, data: Data, title: String?, artist: String?, album: String?) {
        for key in Self.keys(title: title, artist: artist, album: album) {
            guard memory.object(forKey: key as NSString)?.digest != artwork.digest else { continue }
            memory.setObject(artwork, forKey: key as NSString, cost: artwork.cost)
            let file = file(key)
            disk.async { try? data.write(to: file, options: .atomic) }
        }
    }

    private func file(_ key: String) -> URL {
        directory.appending(path: key)
    }

    private static func keys(title: String?, artist: String?, album: String?) -> [String] {
        func key(_ parts: String...) -> String {
            let joined = parts.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.joined(separator: "\u{1F}")
            return Artwork.digest(of: Data(joined.utf8))
        }
        let artist = artist ?? ""
        var keys: [String] = []
        if let title, !title.isEmpty { keys.append(key("track", artist, title)) }
        if let album, !album.isEmpty { keys.append(key("album", artist, album)) }
        return keys
    }

    private nonisolated static func prune(_ directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        guard files.count > diskLimit else { return }
        let dated = files.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(diskLimit) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
