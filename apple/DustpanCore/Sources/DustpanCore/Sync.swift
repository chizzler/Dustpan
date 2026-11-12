import Foundation

/// The sync exchange with an OpenTodo server. See spec/sync.md, "Exchange".
public final class Syncer {
    static let batch = 500
    static let features: JSON = ["backfill_ack", "clock_skew"]
    static let maxSkewRounds = 3

    /// Entities only their author may write; a re-seed sends back only our own.
    static let authored = ["comment": "author_id", "attachment": "author_id", "time_entry": "user_id"]

    public struct Result: Equatable, Sendable {
        public var received = 0  // ops pulled
        public var refused = 0  // local changes the server didn't accept
        public var held = 0  // ops a server limit held back, kept for later
        public var purged = 0  // entities the server deleted for good
    }

    public enum Failure: Error, CustomStringConvertible {
        case unsupportedAccount(String)
        /// The server keeps refusing our ops as too far in the future.
        case clockSkew
        case badResponse(String)

        public var description: String {
            switch self {
            case .unsupportedAccount(let why): why
            case .clockSkew: "this device's clock is far off and the server keeps refusing its changes"
            case .badResponse(let what): "unexpected answer from the server: \(what)"
            }
        }
    }

    let store: Store
    let server: any SyncServer
    let clock: HybridClock

    public init(store: Store, server: any SyncServer, clock: HybridClock? = nil) {
        self.store = store
        self.server = server
        self.clock = clock ?? HybridClock(store: store)
    }

    /// Learn who we are, once. Refuse accounts this client can't handle yet.
    func checkAccount() async throws {
        if !(try store.meta("user_id").isNull) { return }
        let me = try await server.me()
        if me["encryption"]["enabled"].bool == true {
            throw Failure.unsupportedAccount("end-to-end encrypted accounts are not supported yet")
        }
        guard let id = me["user"]["id"].string else { throw Failure.badResponse("/me has no user id") }
        try store.transaction { try store.setMeta("user_id", .string(id)) }
    }

    /// Push edits, pull changes, then send queued purges and pull their markers.
    /// Throws ApiError, Failure or StoreError.
    public func run() async throws -> Result {
        var result = try await exchange()
        if try await sendPurges(store, server) > 0 {
            let again = try await exchange()
            result.received += again.received
            result.refused += again.refused
            result.held = again.held
            result.purged += again.purged
        }
        return result
    }

    /// Exchange until the outbox is empty and nothing remains to pull.
    func exchange() async throws -> Result {
        try await checkAccount()
        let device = try store.transaction { try store.device() }
        var result = Result()
        var skewRounds = 0
        try store.transaction { try requeueHeld() }
        while true {
            let batch = try store.outboxBatch(limit: Self.batch)
            let body: JSON = [
                "device": .string(device),
                "cursor": try store.meta("cursor").isNull ? 0 : try store.meta("cursor"),
                "ops": .array(batch.map(\.op.json)),
                "features": Self.features,
                "backfillAck": .int(try store.meta("backfill_ack").int ?? 0),
                "tzOffset": .int(Int64(TimeZone.current.secondsFromGMT() / 60)),
            ]
            let res = try await server.sync(body)
            guard let serverTime = res["serverTime"].int else { throw Failure.badResponse("no serverTime") }

            let rejected = res["rejected"].array ?? []
            let skewed = rejected.filter { $0["reason"].string == "clock_skew" }
            let limited = rejected.filter { $0["reason"].string?.hasPrefix("limit_") == true }
            let refused = rejected.filter { !skewed.contains($0) && !limited.contains($0) }
            if !skewed.isEmpty {
                skewRounds += 1
                if skewRounds > Self.maxSkewRounds { throw Failure.clockSkew }
            }
            let sent = Dictionary(batch.map { ($0.op.id, $0.op) }, uniquingKeysWith: { first, _ in first })
            let ops = (res["ops"].array ?? []).compactMap(Op.init(json:))
            let purged = res["purged"].array ?? []

            let reseeded = try store.transaction {
                try store.outboxRemove(batch.map(\.seq))
                try clock.followServer(serverTime)
                try restamp(sent, skewed, serverTime)
                result.held = try hold(sent, limited)
                for r in refused {
                    if let id = r["id"].string, let op = sent[id] {
                        try store.forget(op)
                        result.refused += 1
                    }
                }
                if let generation = res["generation"].string, try generationChanged(generation) {
                    try reseed(generation)
                    return true
                }
                for op in ops {
                    try clock.receive(op.ts)
                    try store.apply(op)
                }
                for marker in purged {
                    if let entity = marker["entity"].string, let id = marker["entityId"].string {
                        try store.purge(entity: entity, id: id)
                    }
                }
                if !res["trashRetentionDays"].isNull { try store.setMeta(trashRetentionKey, res["trashRetentionDays"]) }
                if !res["backfillSeq"].isNull { try store.setMeta("backfill_ack", res["backfillSeq"]) }
                try store.setMeta("cursor", res["cursor"])
                return false
            }
            if reseeded { continue }
            result.received += ops.count
            result.purged += purged.count
            if res["hasMore"].bool != true, try store.outboxCount() == 0 { return result }
        }
    }

    /// Stamp ops refused for clock skew again and queue them. Ops that shared a stamp share the new one.
    func restamp(_ sent: [String: Op], _ skewed: [JSON], _ serverTime: Int64) throws {
        let ops = skewed.compactMap { $0["id"].string.flatMap { sent[$0] } }.sorted { $0.ts < $1.ts }
        guard !ops.isEmpty else { return }
        try clock.refused(skewed.lazy.compactMap { $0["serverTime"].int }.first ?? serverTime)
        var fresh: [Int64: Int64] = [:]
        var again: [Op] = []
        for op in ops {
            if fresh[op.ts] == nil { fresh[op.ts] = try clock.stamp() }
            try store.restamp(op, to: fresh[op.ts]!)
            var copy = op
            copy.ts = fresh[op.ts]!
            again.append(copy)
        }
        try store.outboxAdd(again)
    }

    /// Keep ops a server limit refused. Returns how many are held.
    func hold(_ sent: [String: Op], _ limited: [JSON]) throws -> Int {
        var held = (try store.meta("held_ops").array ?? []).compactMap(Op.init(json:))
        var known = Set(held.map(\.id))
        for r in limited {
            if let id = r["id"].string, let op = sent[id], !known.contains(id) {
                held.append(op)
                known.insert(id)
            }
        }
        try store.setMeta("held_ops", .array(held.map(\.json)))
        return held.count
    }

    func requeueHeld() throws {
        let held = (try store.meta("held_ops").array ?? []).compactMap(Op.init(json:))
        if !held.isEmpty {
            try store.outboxAdd(held)
            try store.setMeta("held_ops", [])
        }
    }

    func generationChanged(_ generation: String) throws -> Bool {
        guard !generation.isEmpty else { return false }
        guard let stored = try store.meta("generation").string else {
            try store.setMeta("generation", .string(generation))
            return false
        }
        return stored != generation
    }

    /// The server was restored from a backup: send back everything we hold.
    func reseed(_ generation: String) throws {
        let me = try store.meta("user_id")
        let device = try store.device()
        var authors: [String: [String: JSON]] = [:]
        for (entity, field) in Self.authored {
            authors[entity] = try store.rows(entity).mapValues { $0[field] }
        }
        var ops: [Op] = []
        for f in try store.allFields() {
            if let byId = authors[f.entity], byId[f.entityId] != me { continue }
            if f.entity == "attachment" && f.field == "uploaded_at" { continue }
            // Deviation from the web app, see spec/sync.md, "Re-seed after a restore".
            ops.append(Op(id: UUID().uuidString.lowercased(), entity: f.entity, entityId: f.entityId, field: f.field,
                          value: f.value, ts: f.ts, device: isReservedDevice(f.device) ? device : f.device))
        }
        try store.outboxAdd(ops)
        try store.setMeta("cursor", 0)
        try store.setMeta("backfill_ack", 0)
        try store.setMeta("generation", .string(generation))
    }
}

/// Device ids only the server may write. A batch holding one is refused whole.
let reservedDevicePrefixes = ["agent:", "caldav:", "public:", "issues:", "calsync:", "rule:", "page:"]

public func isReservedDevice(_ device: String) -> Bool {
    device == "server" || device.hasPrefix("server:") || reservedDevicePrefixes.contains { device.hasPrefix($0) }
}
