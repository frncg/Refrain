import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// Decoded artwork, downsampled to `maxPixelSize`, with its average colour and luminance.
final class Artwork {
    let image: NSImage
    let color: Color
    let luminance: Luminance
    /// A deep, saturated version of `color`, to darken the background with without greying it.
    let shade: Color
    /// A light, vivid version of `color`, to lift the background behind dark artwork with.
    let glow: Color
    let digest: String
    let cost: Int

    static let maxPixelSize = 600

    init?(data: Data, digest: String? = nil) {
        guard let cgImage = ImageDownsampling.cgImage(data, maxPixelSize: Self.maxPixelSize) else { return nil }
        image = NSImage(cgImage: cgImage, size: .zero)
        (color, luminance, shade, glow) = Self.analyze(cgImage)
        cost = cgImage.bytesPerRow * cgImage.height
        self.digest = digest ?? Self.digest(of: data)
    }

    #if DEBUG
    init(image: NSImage) {
        self.image = image
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        (color, luminance, shade, glow) = cgImage.map(Self.analyze) ?? Self.blank
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

    /// Relative luminance (linear, 0–1): the average, and the brightest tenth of a 16×16 downscale,
    /// which is about how the heavily blurred background sees it.
    struct Luminance: Equatable {
        var average: Double
        var bright: Double
        /// `shade`'s and `glow`'s.
        var shade: Double
        var glow: Double
    }

    private static let blank = (Color.black, Luminance(average: 0, bright: 0, shade: 0, glow: 0), Color.black, Color.black)

    private static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        min(max(0.2126 * red + 0.7152 * green + 0.0722 * blue, 0), 1)
    }

    /// The average's hue, more saturated (greys stay grey), at a set brightness.
    private static func tone(
        red: Double, green: Double, blue: Double, saturation: Double, brightness: Double
    ) -> (Color, Double) {
        let srgb = NSColor(srgbRed: gammaEncode(red), green: gammaEncode(green), blue: gammaEncode(blue), alpha: 1)
        let deep = NSColor(
            hue: srgb.hueComponent,
            saturation: min(srgb.saturationComponent * saturation, 1),
            brightness: brightness,
            alpha: 1
        )
        guard let components = deep.usingColorSpace(.sRGB) else { return (.black, 0) }
        let luminance = relativeLuminance(
            red: gammaDecode(components.redComponent),
            green: gammaDecode(components.greenComponent),
            blue: gammaDecode(components.blueComponent)
        )
        return (Color(nsColor: deep), luminance)
    }

    private static func gammaEncode(_ value: Double) -> Double {
        let value = min(max(value, 0), 1)
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    private static func gammaDecode(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// From a 16×16 downscale in linear light. Avoids Core Image, whose context keeps GPU caches.
    static func analyze(_ image: CGImage) -> (Color, Luminance, Color, Color) {
        let side = 16
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 32, bytesPerRow: side * 16, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return blank }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data else { return blank }

        let pixels = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: side * side * 4)
        var sum: (red: Float, green: Float, blue: Float) = (0, 0, 0)
        var luminances: [Float] = []
        luminances.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (red, green, blue) = (pixels[index], pixels[index + 1], pixels[index + 2])
            sum.red += red
            sum.green += green
            sum.blue += blue
            luminances.append(min(max(0.2126 * red + 0.7152 * green + 0.0722 * blue, 0), 1))
        }
        let count = Float(side * side)
        let average = (red: sum.red / count, green: sum.green / count, blue: sum.blue / count)
        luminances.sort()
        let (red, green, blue) = (Double(average.red), Double(average.green), Double(average.blue))
        let (shade, shadeLuminance) = tone(red: red, green: green, blue: blue, saturation: 1.5, brightness: 0.4)
        let (glow, glowLuminance) = tone(red: red, green: green, blue: blue, saturation: 1.3, brightness: 0.85)
        let luminance = Luminance(
            average: relativeLuminance(red: red, green: green, blue: blue),
            bright: Double(luminances[luminances.count * 9 / 10]),
            shade: shadeLuminance,
            glow: glowLuminance
        )
        return (Color(.sRGBLinear, red: red, green: green, blue: blue), luminance, shade, glow)
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
