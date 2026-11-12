import SwiftUI

/// The gear in the calendar's toolbar, with the grid's settings in a popover.
struct GridSettingsButton: View {
    @State private var showsSettings = false

    var body: some View {
        Button("Grid Settings", systemImage: "gearshape", action: show)
            .help("Grid hours and day length")
            .popover(isPresented: $showsSettings) { GridSettings() }
    }

    private func show() { showsSettings = true }
}
