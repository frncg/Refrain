import AppKit
import SwiftUI

/// Reports whether the hosting window is on screen. A menu bar window is hidden, not
/// destroyed, when it closes, so its views' `onDisappear` isn't reliable.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { isVisible = $0 }
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let window {
                let names: [Notification.Name] = [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.didBecomeKeyNotification,
                    NSWindow.didResignKeyNotification,
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.report() }
                    }
                }
            }
            report()
        }

        private func report() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            guard visible != lastReported else { return }
            lastReported = visible
            // Deferred: this can run while SwiftUI is updating the view.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }
    }
}
