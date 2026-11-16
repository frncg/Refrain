import AppKit
import CoreServices

/// Whether Refrain may control an app over Apple Events (used to read browser tabs).
enum AutomationPermission {
    enum Status { case allowed, denied, notAsked }

    /// Never prompts. Nil when it can't tell, e.g. the app isn't running.
    static func status(for bundleIdentifier: String) -> Status? {
        var target = AEAddressDesc()
        let id = Array(bundleIdentifier.utf8)
        guard AECreateDesc(typeApplicationBundleID, id, id.count, &target) == noErr else { return nil }
        defer { AEDisposeDesc(&target) }
        switch Int(AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)) {
        case Int(noErr): return .allowed
        case errAEEventNotPermitted: return .denied
        case errAEEventWouldRequireUserConsent: return .notAsked
        default: return nil
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
