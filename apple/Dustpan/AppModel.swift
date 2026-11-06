import DustpanCore
import Foundation
import Observation

enum Page: Hashable {
    case inbox
    case project(String)
}

/// The window's state: the local copy as last read, and how sync is going.
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case syncing
        case offline(String)
        case failed(String)
    }

    static let pollInterval = Duration.seconds(30)

    private(set) var snapshot = Snapshot()
    private(set) var status = Status.idle
    /// Why the app can't start: no config, or no database.
    private(set) var setupProblem: String?
    var page: Page? = .inbox

    private let store: Store?
    private let syncer: Syncer?

    init() {
        var store: Store?
        var syncer: Syncer?
        do {
            let config = try Config.load()
            store = try Store(path: try databasePath())
            syncer = Syncer(store: store!, server: Api(config: config))
            snapshot = try DustpanCore.snapshot(store!)
        } catch {
            setupProblem = "\(error)"
        }
        self.store = store
        self.syncer = syncer
    }

    /// Sync at start, then every 30 seconds while the window is open.
    func start() async {
        guard syncer != nil else { return }
        await sync()
        #if DEBUG
        await screenshotsIfAsked()
        #endif
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.pollInterval)
            await sync()
        }
    }

    func sync() async {
        guard let store, let syncer, status != .syncing else { return }
        status = .syncing
        do {
            _ = try await syncer.run()
            snapshot = try DustpanCore.snapshot(store)
            status = .idle
        } catch ApiError.offline(let message) {
            status = .offline(message)
        } catch {
            status = .failed("\(error)")
        }
    }

    /// Every visible project by id, nested ones included.
    var projectsById: [String: Node] {
        var byId: [String: Node] = [:]
        func walk(_ nodes: [Node]) {
            for node in nodes {
                byId[node.id] = node
                walk(node.children)
            }
        }
        walk(snapshot.projects)
        return byId
    }
}
