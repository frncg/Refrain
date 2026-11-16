import AppKit
import QuartzCore
import SwiftUI

extension View {
    /// Holds the display at 60Hz or more while this view is on screen, so animations in its
    /// window don't drop below 60fps when macOS adaptively lowers a ProMotion display's rate.
    func highFrameRate() -> some View {
        background(HighFrameRate())
    }
}

private struct HighFrameRate: NSViewRepresentable {
    func makeNSView(context: Context) -> DisplayLinkView {
        DisplayLinkView()
    }

    func updateNSView(_ view: DisplayLinkView, context: Context) {}

    static func dismantleNSView(_ view: DisplayLinkView, coordinator: ()) {
        view.stop()
    }

    final class DisplayLinkView: NSView {
        static let frameRate = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        private var link: CADisplayLink?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            // An empty callback: the frame rate request is what matters.
            let link = displayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = Self.frameRate
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        /// The link retains this view, so it's invalidated whenever the view leaves its window.
        func stop() {
            link?.invalidate()
            link = nil
        }

        @objc private func tick(_ link: CADisplayLink) {}
    }
}
