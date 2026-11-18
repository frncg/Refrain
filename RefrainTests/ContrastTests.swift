import AppKit
import Testing
@testable import Refrain

struct ContrastTests {
    private func artwork(_ color: NSColor) -> Artwork {
        Artwork(image: NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        })
    }

    @Test func darkArtworkIsntDimmed() {
        #expect(BlurredArtworkBackground.scrimOpacity(for: artwork(.black).luminance) == 0)
        #expect(BlurredArtworkBackground.scrimOpacity(for: artwork(NSColor(white: 0.3, alpha: 1)).luminance) == 0)
    }

    @Test(arguments: [NSColor.white, .yellow, .cyan, NSColor(white: 0.75, alpha: 1)])
    func brightArtworkReachesTheContrast(color: NSColor) {
        let luminance = artwork(color).luminance
        let scrim = BlurredArtworkBackground.scrimOpacity(for: luminance)
        #expect(scrim > 0)
        let background = BlurredArtworkBackground.backgroundLuminance(for: luminance) * (1 - scrim * (1 - luminance.shade))
        #expect((1.05 / (background + 0.05)) >= BlurredArtworkBackground.textContrast - 0.001)
    }

    @Test(arguments: [NSColor.black, NSColor(red: 0.12, green: 0.02, blue: 0.15, alpha: 1)])
    func darkArtworkLiftsTheBackground(color: NSColor) {
        let luminance = artwork(color).luminance
        let lift = BlurredArtworkBackground.liftOpacity(for: luminance)
        #expect(lift > 0)
        let average = BlurredArtworkBackground.averageBackgroundLuminance(for: luminance)
        let lifted = average + lift * luminance.glow * (1 - average)
        let separation = (lifted + 0.05) / (luminance.average + 0.05)
        #expect(separation >= min(BlurredArtworkBackground.separation, (0.12 + 0.05) / (luminance.average + 0.05)) - 0.01)
        // White text keeps its contrast against the lifted background.
        let bright = BlurredArtworkBackground.backgroundLuminance(for: luminance)
        let liftedBright = bright + lift * luminance.glow * (1 - bright)
        #expect(1.05 / (liftedBright + 0.05) >= BlurredArtworkBackground.textContrast - 0.001)
    }

    @Test func brightArtworkIsntLifted() {
        #expect(BlurredArtworkBackground.liftOpacity(for: artwork(.white).luminance) == 0)
        #expect(BlurredArtworkBackground.liftOpacity(for: artwork(.yellow).luminance) == 0)
    }

    @Test func brightestTenthDecides() {
        // A white cover with a black band over most of it still has white areas behind the text.
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: 64, height: 48).fill()
            return true
        }
        let luminance = Artwork(image: image).luminance
        #expect(luminance.bright > 0.9)
        #expect(luminance.average < 0.4)
    }
}
