#if DEBUG
import AppKit
import ScreenCaptureKit

extension AppModel {
    /// DUSTPAN_SCREENSHOT=<folder>: after the first sync, save one PNG per sidebar page, then quit.
    /// An app may capture its own windows without the Screen Recording permission.
    func screenshotsIfAsked() async {
        guard let folder = ProcessInfo.processInfo.environment["DUSTPAN_SCREENSHOT"], !folder.isEmpty else { return }
        let pages: [(String, Page)] = [("inbox", .inbox)]
            + projectsById.values.map { ($0.row["name"].string ?? $0.id, Page.project($0.id)) }.sorted { $0.0 < $1.0 }
        for (index, (name, page)) in pages.enumerated() {
            self.page = page
            try? await Task.sleep(for: .milliseconds(600))
            guard let window = try? await SCShareableContent.currentProcess.windows.first(where: \.isOnScreen) else {
                continue
            }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width) * 2
            config.height = Int(window.frame.height) * 2
            guard let image = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config) else { continue }
            let file = URL(filePath: folder).appending(path: String(format: "%02d-%@.png", index, name))
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
        }
        NSApp.terminate(nil)
    }
}
#endif
