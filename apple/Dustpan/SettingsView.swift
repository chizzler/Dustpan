import SwiftUI

/// Dustpan ▸ Settings (⌘,): preferences, which sync with the account once connected, and OpenTodo sync itself.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                PreferencesForm(prefs: model.snapshot.prefs)
            }
            Tab("Sync", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettings(config: model.config)
            }
        }
        .frame(width: 520)
    }
}
