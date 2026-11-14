import Foundation
import ServiceManagement

/// Opening Dustpan at login, so reminders show whenever this Mac is logged in: they only fire while Dustpan runs.
/// Mac only; the iPhone app will schedule its notifications with the system instead.
enum LoginItem {
    /// UserDefaults: the one-time offer has been made on this Mac.
    static let offeredKey = "offeredOpenAtLogin"

    /// Only an installed copy, in an Applications folder, so a development build never opens at login on the
    /// real data.
    static var canChange: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        return FileManager.default.urls(for: .applicationDirectory, in: .allDomainsMask)
            .contains { $0.standardizedFileURL.path == path }
    }

    /// Registered, whether or not macOS has been allowed to open it yet.
    static var isOn: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }

    /// On, but macOS wants it allowed in System Settings ▸ General ▸ Login Items first.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
            if needsApproval { SMAppService.openSystemSettingsLoginItems() }
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
