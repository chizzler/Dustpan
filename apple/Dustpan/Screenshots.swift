#if DEBUG
import AppKit
import ScreenCaptureKit

extension AppModel {
    /// DUSTPAN_SCREENSHOT=<folder>: after the first sync, save one PNG per sidebar page, then quit.
    /// An app may capture its own windows without the Screen Recording permission.
    func screenshotsIfAsked() async {
        guard let folder = ProcessInfo.processInfo.environment["DUSTPAN_SCREENSHOT"], !folder.isEmpty else { return }
        if showsWelcome {
            NSApp.activate()
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            await capture("welcome.png", in: folder) { _ in true }
            NSApp.terminate(nil)
            return
        }
        let pages: [(String, Page)] = [("today", .today), ("upcoming", .upcoming), ("inbox", .inbox)]
            + Page.optional.map { ($0.key ?? "", $0) }
            + projectsById.values.map { ($0.row["name"].string ?? $0.id, Page.project($0.id)) }.sorted { $0.0 < $1.0 }
            + snapshot.labelsInOrder.map { ("label-" + ($0["name"].string ?? $0.id), Page.label($0.id)) }
        // The calendar, when it's open, is captured once, apart from the main window's pages.
        let calendar = NSApp.windows.first { $0.identifier?.rawValue.contains(CalendarWindow.id) == true }?.windowNumber
        for (index, (name, page)) in pages.enumerated() {
            self.page = page
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            await capture(String(format: "%02d-%@.png", index, name), in: folder) { $0 != calendar }
        }
        if let calendar { await capture("calendar.png", in: folder) { $0 == calendar } }
        NSApp.terminate(nil)
    }

    /// Save the first of this app's windows on screen that number allows.
    private func capture(_ name: String, in folder: String, where allows: (Int) -> Bool) async {
        // currentProcess lists the desktop's windows too (macOS 27): take this app's own.
        let ours = ProcessInfo.processInfo.processIdentifier
        guard let window = try? await SCShareableContent.currentProcess.windows.first(where: {
            $0.isOnScreen && $0.owningApplication?.processID == ours && $0.windowLayer == 0 && allows(Int($0.windowID))
        }) else { return }
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(filePath: folder).appending(path: name))
    }
}
#endif
