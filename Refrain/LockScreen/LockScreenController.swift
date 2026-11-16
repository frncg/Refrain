import AppKit
import SwiftUI
import SkyLightWindow

/// Shows `LockScreenOverlay` while the screen is locked. Typing collapses it to the
/// miniplayer so the real password field shows; only key timing is read, never keys.
@MainActor
final class LockScreenController {
    private static let expandAfterTyping: TimeInterval = 10

    private let music: MusicController
    private var panel: NSPanel?
    private var overlayState: LockScreenOverlayState?
    private var observers: [NSObjectProtocol] = []
    /// Keeps App Nap from stalling timers while locked.
    private var lockedActivity: NSObjectProtocol?
    private var keyWatch: Timer?
    private var lastKeyIdle: TimeInterval = 0
    private var collapsedForTyping = false

    init(music: MusicController) {
        self.music = music

        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenLocked() }
        })
        observers.append(center.addObserver(
            forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenUnlocked() }
        })
    }

    private func screenLocked() {
        lockedActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Showing now playing on the lock screen"
        )
        guard music.title != nil, music.isMusicSource else { return }
        show()
        startWatchingKeys()
    }

    private func screenUnlocked() {
        stopWatchingKeys()
        hide()
        if let lockedActivity {
            ProcessInfo.processInfo.endActivity(lockedActivity)
        }
        lockedActivity = nil
    }

    private func show() {
        guard panel == nil, let screen = NSScreen.screens.first else { return }

        let state = LockScreenOverlayState()
        let panel = LockScreenPanel(screen: screen)
        panel.contentView = NSHostingView(rootView: LockScreenOverlay(
            music: music,
            state: state,
            onExit: { [weak self] in self?.dismiss() }
        ))
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        SkyLightOperator.shared.delegateWindow(panel)
        panel.orderFrontRegardless()
        self.panel = panel
        overlayState = state

        fade(to: 1, duration: 0.5)
    }

    private func hide() {
        panel?.close()
        panel = nil
        overlayState = nil
        collapsedForTyping = false
    }

    private func dismiss() {
        stopWatchingKeys()
        fade(to: 0, duration: 0.3) { [weak self] in
            self?.hide()
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        panel.ignoresMouseEvents = alpha == 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        } completionHandler: {
            completion?()
        }
    }

    // MARK: - Collapsing for the password field

    private func startWatchingKeys() {
        lastKeyIdle = Self.secondsSinceLastKeyPress
        keyWatch = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkKeys() }
        }
    }

    private func stopWatchingKeys() {
        keyWatch?.invalidate()
        keyWatch = nil
    }

    private func checkKeys() {
        let idle = Self.secondsSinceLastKeyPress
        let newKeyPress = idle < lastKeyIdle
        lastKeyIdle = idle

        guard let overlayState else { return }
        if newKeyPress {
            guard overlayState.expanded else { return }
            collapsedForTyping = true
            setExpanded(false, in: overlayState)
        } else if collapsedForTyping, idle > Self.expandAfterTyping {
            collapsedForTyping = false
            if !overlayState.expanded {
                setExpanded(true, in: overlayState)
            }
        }
    }

    private func setExpanded(_ expanded: Bool, in state: LockScreenOverlayState) {
        withAnimation(NowPlayingTransition().animation) {
            state.expanded = expanded
        }
    }

    private static var secondsSinceLastKeyPress: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }
}

/// Never becomes key, so typing on the lock screen always reaches loginwindow.
private final class LockScreenPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        canBecomeVisibleWithoutLogin = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        level = NSWindow.Level(rawValue: Int(Int32.max - 2))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
