import DustpanCore
import SwiftUI

/// Settings ▸ Sync: connect to an OpenTodo server, switch accounts, or disconnect and keep working here.
/// Writes ~/.config/dustpan/config, which the desktop client reads too.
struct SyncSettings: View {
    @Environment(AppModel.self) private var model
    @State private var url: String
    @State private var token: String
    @State private var busy = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var joining: AccountToJoin?
    @State private var choosesAccount = false
    @State private var confirmsDisconnect = false
    @State private var operation: Task<Void, Never>?

    init(config: Config?) {
        _url = State(initialValue: config?.url.absoluteString ?? "")
        _token = State(initialValue: config?.token ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $url, prompt: Text("https://todo.example.com"))
                    .textContentType(.URL)
                SecureField("API token", text: $token)
            } header: {
                Text("OpenTodo Sync")
            } footer: {
                Text(description)
            }
            .onSubmit(connect)
            .disabled(busy)

            Section {
                HStack {
                    Button(model.isConnected ? "Save & Reconnect" : "Connect to OpenTodo", action: connect)
                        .keyboardShortcut(.defaultAction)
                        .confirmationDialog("Switch OpenTodo account?", isPresented: $choosesAccount,
                                            presenting: joining) { account in
                            Button("Upload Local Tasks") { join(account, .upload) }
                            Button("Replace Local Data", role: .destructive) { join(account, .replace) }
                        } message: { _ in
                            Text("This Mac holds tasks synced with another OpenTodo account. Upload them into the new "
                                 + "account, or replace the data here with the new account's?")
                        }
                    if model.isConnected {
                        Button("Disconnect…", role: .destructive) { confirmsDisconnect = true }
                            .confirmationDialog("Disconnect from OpenTodo?", isPresented: $confirmsDisconnect) {
                                Button("Disconnect", role: .destructive, action: disconnect)
                            } message: {
                                Text("Sync stops. Your tasks, projects and settings stay on this Mac.")
                            }
                    }
                    Spacer()
                    if busy {
                        ProgressView().controlSize(.small)
                        Text(model.changingAccount ? "Waiting for sync…" : "Connecting…")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(busy)
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                } else if let notice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { operation?.cancel() }
    }

    private var description: String {
        if let config = model.config {
            return "Connected to \(config.url.absoluteString). Edits work offline and sync when the server can be reached."
        }
        return "Optional. Tasks live on this Mac. Connect an OpenTodo server whenever you want to sync across "
            + "devices; the tasks here are uploaded."
    }

    private func connect() {
        guard !busy else { return }
        (problem, notice) = (nil, nil)
        let config: Config
        do {
            config = try Config.validate(url: url, token: token)
        } catch {
            problem = error.message
            return
        }
        run {
            let (userId, key) = try await model.verify(config)
            try Task.checkCancellation()
            guard let how = try model.joinPlan(for: userId) else {
                joining = AccountToJoin(config: config, userId: userId, key: key)
                choosesAccount = true
                return false
            }
            try await model.connect(config, userId: userId, key: key, how)
            return true
        }
    }

    private func join(_ account: AccountToJoin, _ how: AccountJoin) {
        run {
            try await model.connect(account.config, userId: account.userId, key: account.key, how)
            return true
        }
    }

    /// Busy while work runs; then whether it connected, or why not.
    private func run(_ work: @escaping () async throws -> Bool) {
        busy = true
        operation = Task {
            defer { busy = false }
            do {
                if try await work() { notice = "Connected to OpenTodo." }
            } catch is CancellationError {
                return
            } catch {
                problem = Self.explain(error)
            }
        }
    }

    private func disconnect() {
        run {
            try await model.disconnect()
            (url, token, problem) = ("", "", nil)
            notice = "Disconnected. Working on this Mac only."
            return false
        }
    }

    private static func explain(_ error: Error) -> String {
        switch error {
        case ApiError.offline: "Couldn't reach the server. Check the URL and your connection."
        case ApiError.server(let status, _, _) where status == 401 || status == 403:
            "The server didn't accept the token. Check your API token."
        case ApiError.server(_, _, let message): "Server error: \(message)"
        case Syncer.Failure.unsupportedAccount(let why): "Can't connect: \(why)"
        case let error as CannotEdit: error.message
        default: "\(error)"
        }
    }
}
