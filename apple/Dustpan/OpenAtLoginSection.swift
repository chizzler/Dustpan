import ServiceManagement
import SwiftUI

/// Settings ▸ General: whether Dustpan opens at login, for this Mac only.
struct OpenAtLoginSection: View {
    @State private var isOn = LoginItem.isOn
    @State private var needsApproval = LoginItem.needsApproval
    @State private var problem: String?
    @State private var showsProblem = false

    var body: some View {
        Section {
            Toggle(isOn: $isOn) {
                Text("Open at login")
                Text("Reminders only appear while Dustpan is running")
            }
            .disabled(!LoginItem.canChange)
            if needsApproval {
                Button("Allow in System Settings…", action: openLoginItems)
            }
        } footer: {
            Text(LoginItem.canChange ? "For this Mac only." : "Move Dustpan to Applications to open it at login.")
        }
        .onChange(of: isOn, change)
        .alert("Couldn't change opening at login", isPresented: $showsProblem, presenting: problem) { _ in
        } message: { Text($0) }
    }

    private func change() {
        guard isOn != LoginItem.isOn else { return }
        do {
            try LoginItem.set(isOn)
        } catch {
            problem = error.localizedDescription
            showsProblem = true
            isOn = LoginItem.isOn
        }
        needsApproval = LoginItem.needsApproval
    }

    private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
