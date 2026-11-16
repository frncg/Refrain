//
//  ArtworkCache.swift
//  MusicPlayer
//

import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Decoded artwork and its average colour.
final class Artwork {
    /// At most `maxPixelSize`: payloads can carry artwork of several thousand
    /// pixels, tens of MB once decoded, for a 280pt view and a blurred background.
    let image: NSImage
    /// The background's base colour (see `BlurredArtworkBackground`).
    let color: Color
    /// SHA-256 of the image data, to tell repeated payloads from new artwork.
    let digest: String
    /// Decoded size in bytes, for `ArtworkCache`'s memory limit.
    let cost: Int

    /// The largest artwork is 280pt in the full player, 560px on a 2x screen.
    static let maxPixelSize = 600

    init?(data: Data, digest: String? = nil) {
        guard let cgImage = ImageDownsampling.cgImage(data, maxPixelSize: Self.maxPixelSize) else { return nil }
        image = NSImage(cgImage: cgImage, size: .zero)
        color = Self.averageColor(of: cgImage)
        cost = cgImage.bytesPerRow * cgImage.height
        self.digest = digest ?? Self.digest(of: data)
    }

    #if DEBUG
    init(image: NSImage) {
        self.image = image
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        color = cgImage.map(Self.averageColor) ?? .black
        cost = 0
        digest = UUID().uuidString
    }
    #endif

    static func digest(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Averaged in linear light, like a blur mixes colours, from a 16×16
    /// downscale. Avoids Core Image, whose context keeps GPU caches alive.
    private static func averageColor(of image: CGImage) -> Color {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 32, bytesPerRow: side * 16, space: space,
                  // Host-order floats: Core Graphics defaults to big-endian.
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return .black }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return .black }

        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: side * side * 4)
        var sum: (red: Float, green: Float, blue: Float) = (0, 0, 0)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sum.red += pixels[index]
            sum.green += pixels[index + 1]
            sum.blue += pixels[index + 2]
        }
        let count = Float(side * side)
        return Color(.sRGBLinear, red: Double(sum.red / count), green: Double(sum.green / count), blue: Double(sum.blue / count))
    }
}

/// Decodes images straight to the size they're shown at, without keeping the
/// original data or a full-size bitmap around.
enum ImageDownsampling {
    static func cgImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        // Never upscales: smaller images come back at their own size.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    static func image(_ data: Data, maxPixelSize: Int) -> NSImage? {
        cgImage(data, maxPixelSize: maxPixelSize).map { NSImage(cgImage: $0, size: .zero) }
    }
}

/// Artwork seen before, so a track shows its artwork as soon as it starts
/// instead of when the player gets round to sending it. Kept in memory and in
/// ~/Library/Caches, under both the track and its album, so the next track on
/// an album that's played before is instant too.
@MainActor
final class ArtworkCache {
    private nonisolated static let diskLimit = 300

    private let memory = NSCache<NSString, Artwork>()
    private let directory: URL
    private let disk = DispatchQueue(label: "ArtworkCache", qos: .utility)

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "MusicPlayer")
            .appending(path: "Artwork")
        // About 9 MB: 6 entries, so 3 to 6 covers (each is filed under its
        // track and its album). Covers are decoded (1.4 MB at 600px), and a
        // 50-entry cache measured 53–71 MB; one that aged out reloads from
        // disk in a millisecond or two.
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
            // Small files; reading on the main thread keeps the track change
            // and its artwork in the same frame.
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

    /// Track first, then album.
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

    /// Keeps the most recently written files.
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
