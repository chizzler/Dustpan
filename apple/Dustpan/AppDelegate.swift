import AppKit

/// AppKit's word on quitting, which SwiftUI doesn't give: windows that close as the app quits stay open next time.
/// Mac only; the iPhone app has no windows to reopen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) static var quitting = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.quitting = true
        return .terminateNow
    }
}
