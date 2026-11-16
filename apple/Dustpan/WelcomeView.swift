import SwiftUI

/// The first launch groups each storage choice with its explanation and final action.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var connects = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("Welcome to Dustpan").font(.largeTitle.bold())
                    Text("Taking tasks to task since 2026")
                        .font(.title3).foregroundStyle(.secondary)
                }
                WelcomeChoice(symbol: "internaldrive",
                              title: model.isConnected ? "Keep your current setup" : "On this Mac",
                              detail: model.isConnected
                                ? "Dustpan is already connected to your server. Continue with your existing tasks and sync settings."
                                : "Keep your tasks on this Mac, no syncing with other devices. You can connect a server later in Settings.",
                              accent: .blue) {
                    Button(action: model.finishWelcome) {
                        Text(model.isConnected ? "Continue to Dustpan" : "Standalone on This Mac")
                            .frame(minWidth: 240).padding(.vertical, 6)
                    }
                }
                WelcomeChoice(symbol: "arrow.triangle.2.circlepath",
                              title: model.isConnected ? "Change your sync settings" : "Sync between devices",
                              detail: model.isConnected
                                ? "Review your server connection or connect another account. Disconnecting keeps your tasks on this Mac."
                                : "Keep a copy on this Mac and sync through your own OpenTodo server. You’ll need its HTTPS address and an API token.",
                              accent: .orange) {
                    Button { connects = true } label: {
                        Text(model.isConnected ? "Open Sync Settings…" : "Sync to an OpenTodo Server…")
                            .frame(minWidth: 240).padding(.vertical, 6)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 580, height: 640)
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $connects) { WelcomeSyncView() }
        .onChange(of: model.isConnected) { _, connected in
            if connected { connects = false; model.finishWelcome() }
        }
    }
}
