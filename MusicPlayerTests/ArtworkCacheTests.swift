//
//  ArtworkCacheTests.swift
//  MusicPlayerTests
//

import AppKit
import SwiftUI
import Testing
@testable import MusicPlayer

@MainActor
struct ArtworkCacheTests {

    @Test func averageColorOfASolidImage() throws {
        let artwork = try #require(Artwork(data: png(.systemRed)))
        let color = try #require(NSColor(artwork.color).usingColorSpace(.sRGB))
        let red = try #require(NSColor.systemRed.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - red.redComponent) < 0.02)
        #expect(abs(color.greenComponent - red.greenComponent) < 0.02)
        #expect(abs(color.blueComponent - red.blueComponent) < 0.02)
    }

    @Test func findsArtworkByTrackThenAlbum() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = png(.systemBlue)
        let artwork = try #require(Artwork(data: data))

        let cache = ArtworkCache(directory: directory)
        cache.store(artwork, data: data, title: "Song One", artist: "Artist", album: "Album")

        #expect(cache.artwork(title: "Song One", artist: "Artist", album: nil)?.digest == artwork.digest)
        // Another track on the same album.
        #expect(cache.artwork(title: "Song Two", artist: "Artist", album: "Album")?.digest == artwork.digest)
        #expect(cache.artwork(title: "Song Two", artist: "Someone Else", album: "Album") == nil)
    }

    @Test func survivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = png(.systemGreen)
        let artwork = try #require(Artwork(data: data))
        ArtworkCache(directory: directory).store(artwork, data: data, title: "Song", artist: "Artist", album: "Album")

        // Disk writes are asynchronous.
        let fresh = ArtworkCache(directory: directory)
        var found: Artwork?
        for _ in 0..<50 where found == nil {
            try await Task.sleep(for: .milliseconds(20))
            found = fresh.artwork(title: "Song", artist: "Artist", album: "Album")
        }
        #expect(found?.digest == artwork.digest)
    }

    private func png(_ color: NSColor) -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return bitmap.representation(using: .png, properties: [:])!
    }
}
