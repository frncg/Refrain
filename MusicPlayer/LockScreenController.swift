//
//  LockScreenController.swift
//  MusicPlayer
//

import AppKit
import SwiftUI
import SkyLightWindow

/// Covers the lock screen with `LockScreenOverlay` while the screen is locked.
///
/// The overlay can't take keyboard focus, so typing always reaches
/// loginwindow's password field. When a key is pressed the overlay collapses to
/// the miniplayer, which leaves the real lock screen (and that field) visible,
/// and expands again after a pause in typing. Only the time since the last key
/// press is read, never which key.
@MainActor
final class LockScreenController {
    /// How long after the last key press a typing-collapsed overlay expands again.
    private static let expandAfterTyping: TimeInterval = 10

    private let music: MusicController
    private var panel: NSPanel?
    private var overlayState: LockScreenOverlayState?
    private var observers: [NSObjectProtocol] = []
    /// While locked none of our windows count as visible, so App Nap would
    /// throttle timers (playback time, lyric sync) and delay async work.
    private var lockedActivity: NSObjectProtocol?
    private var keyWatch: Timer?
    private var lastKeyIdle: TimeInterval = 0
    /// Set when typing collapsed the overlay, so only that collapse is undone
    /// automatically; one the user chose stays collapsed.
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
        // Only for music apps and music websites, not videos or calls.
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

    /// Also usable without locking, to preview the overlay.
    func show() {
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

    /// Also turns karaoke off: its button is only on the overlay.
    func hide() {
        Karaoke.shared.stop()
        panel?.close()
        panel = nil
        overlayState = nil
        collapsedForTyping = false
    }

    /// Fades out, then closes until the next lock.
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
        // The idle time only drops when a new key is pressed.
        let newKeyPress = idle < lastKeyIdle
        lastKeyIdle = idle

        guard let overlayState else { return }
        if newKeyPress {
            guard overlayState.expanded else { return }
            collapsedForTyping = true
            setExpanded(false, in: overlayState)
        } else if collapsedForTyping, idle > Self.expandAfterTyping {
            collapsedForTyping = false
            // The user may have expanded it themselves in the meantime.
            if !overlayState.expanded {
                setExpanded(true, in: overlayState)
            }
        }
    }

    /// Same animation as the artwork and miniplayer taps.
    private func setExpanded(_ expanded: Bool, in state: LockScreenOverlayState) {
        withAnimation(NowPlayingTransition().animation) {
            state.expanded = expanded
        }
    }

    private static var secondsSinceLastKeyPress: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown)
    }
}

/// Never becomes key, so key presses on the lock screen always go to
/// loginwindow rather than to this app.
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
