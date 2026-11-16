import SwiftUI

struct WelcomeSyncView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sync with your server").font(.title2.bold())
                Text("Use the HTTPS address and a device-specific API token from your OpenTodo server. You can also start locally and connect later.")
                    .foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            SyncSettings(config: model.config)
            HStack {
                Button("Back") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
            }.padding(20)
        }
        .frame(width: 520, height: 420)
    }
}
