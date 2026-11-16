import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Decoded artwork, downsampled to `maxPixelSize`, with its average colour.
final class Artwork {
    let image: NSImage
    let color: Color
    let digest: String
    let cost: Int

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

    /// Averaged in linear light from a 16×16 downscale. Avoids Core Image, whose context keeps GPU caches.
    private static func averageColor(of image: CGImage) -> Color {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 32, bytesPerRow: side * 16, space: space,
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

enum ImageDownsampling {
    static func cgImage(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
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
