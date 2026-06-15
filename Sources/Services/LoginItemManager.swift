import Foundation
import ServiceManagement

enum LoginItemManager {
    /// The user's saved intent, persisted in UserDefaults so it survives
    /// reinstalls and OS updates. The OS-level SMAppService registration is
    /// keyed to a specific app bundle, so replacing the bundle (every
    /// `./build.sh --install`) or a macOS upgrade can silently drop it — but
    /// this flag remembers what the user asked for.
    private static let intentKey = "launchAtLoginIntent"

    static var wantsLaunchAtLogin: Bool {
        UserDefaults.standard.bool(forKey: intentKey)
    }

    /// True only when the app is actually registered with the OS right now.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        UserDefaults.standard.set(enabled, forKey: intentKey)
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Re-asserts the OS registration to match the saved intent. Call once at
    /// launch: if the user wanted launch-at-login but the registration was
    /// dropped (reinstall / OS update), this silently re-registers it.
    static func reconcile() {
        guard wantsLaunchAtLogin else { return }
        guard SMAppService.mainApp.status != .enabled else { return }
        try? SMAppService.mainApp.register()
    }
}
