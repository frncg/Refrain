import Foundation
import ServiceManagement

/// Registers as a login item on first launch only, so turning it off in System Settings sticks.
enum LoginItem {
    private static let registeredKey = "registeredLoginItem"

    static func registerOnce() {
        // Debug builds run from DerivedData, and would set the flag for the installed app.
        #if !DEBUG
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: registeredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            defaults.set(true, forKey: registeredKey)
        } catch {
            print("Couldn't register as a login item: \(error)")
        }
        #endif
    }
}
