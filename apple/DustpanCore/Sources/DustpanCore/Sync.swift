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
        /// The token belongs to another account than the data here. Settings decides what to do with it.
        case accountMismatch
        /// The account changed while this sync ran. Nothing from it was kept.
        case accountChanged(String)
        /// The server keeps refusing our ops as too far in the future.
        case clockSkew
        case badResponse(String)

        public var description: String {
            switch self {
            case .unsupportedAccount(let why), .accountChanged(let why): why
            case .accountMismatch:
                "this device holds data from another OpenTodo account; reconnect in Settings to choose how to handle it"
            case .clockSkew: "this device's clock is far off and the server keeps refusing its changes"
            case .badResponse(let what): "unexpected answer from the server: \(what)"
            }
        }
    }

    let store: Store
    let server: any SyncServer
    let clock: HybridClock
    /// Who this sync is for, and the account epoch it started under.
    var userId: String?
    var epoch: Int64 = 0

    public init(store: Store, server: any SyncServer, clock: HybridClock? = nil) {
        self.store = store
        self.server = server
        self.clock = clock ?? HybridClock(store: store)
    }

    /// Learn who we are: once per account, adopting standalone data on its first connection.
    func checkAccount() async throws {
        let stored = try store.meta("user_id").string
        let key = server.accountKey, storedKey = try store.meta("account_key")
        if !isLocalUser(stored), let stored, key == nil || storedKey == key {
            userId = stored
            return
        }
        let (id, verifiedKey) = try await verifyAccount(server)
        userId = id
        if isLocalUser(stored) {
            try adoptStandalone(store, userId: id, accountKey: verifiedKey)
            return
        }
        guard stored == id else { throw Failure.accountMismatch }
        try store.transaction { try rememberAccountKey(store, verifiedKey) }
    }

    /// Push edits, pull changes, then send queued purges and pull their markers.
    /// Throws ApiError, Failure or StoreError.
    public func run() async throws -> Result {
        try await checkAccount()
        try store.transaction {
            // Pin the account this sync belongs to. A switch after this is caught by checkSameAccount.
            epoch = try store.meta(accountEpochKey).int ?? 0
            if try store.meta("user_id").string != userId {
                throw Failure.accountChanged("the account changed before sync started")
            }
        }
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

    /// Call inside a transaction.
    func checkSameAccount() throws {
        if try store.meta(accountEpochKey).int ?? 0 != epoch {
            throw Failure.accountChanged("the account changed during sync; nothing from that sync was kept")
        }
    }

    /// Up to a batch of ops, without splitting a reminder, comment, attachment or time entry across requests.
    func nextBatch() throws -> [(seq: Int64, op: Op)] {
        let batch = try store.outboxBatch(limit: Self.batch + 1)
        guard batch.count > Self.batch else { return batch }
        let split = Array(batch.prefix(Self.batch))
        let tail = split.last!.op
        guard batchWhole.contains(tail.entity), batch[Self.batch].op.entity == tail.entity,
              batch[Self.batch].op.entityId == tail.entityId else { return split }
        let trimmed = split.filter { $0.op.entity != tail.entity || $0.op.entityId != tail.entityId }
        return trimmed.isEmpty ? split : trimmed
    }

    /// Exchange until the outbox is empty and nothing remains to pull.
    func exchange() async throws -> Result {
        let device = try store.transaction { try store.device() }
        var result = Result()
        var skewCounts: [String: Int] = [:]
        try store.transaction {
            try checkSameAccount()
            try requeueHeld()
        }
        while true {
            let (batch, body) = try store.transaction {
                try checkSameAccount()
                let batch = try nextBatch()
                let body: JSON = [
                    // A restore can bring back fields we no longer hold, our own old writes too. Pull under a
                    // temporary identity so the server sends them.
                    "device": .string(try store.meta("reseed_device").string ?? device),
                    "cursor": try store.meta("cursor").isNull ? 0 : try store.meta("cursor"),
                    "ops": .array(batch.map(\.op.json)),
                    "features": Self.features,
                    "backfillAck": .int(try store.meta("backfill_ack").int ?? 0),
                    "tzOffset": .int(Int64(TimeZone.current.secondsFromGMT() / 60)),
                ]
                return (batch, body)
            }
            let res = try await server.sync(body)
            guard let serverTime = res["serverTime"].int else { throw Failure.badResponse("no serverTime") }

            let rejected = res["rejected"].array ?? []
            let skewed = rejected.filter { $0["reason"].string == "clock_skew" }
            let limited = rejected.filter { $0["reason"].string?.hasPrefix("limit_") == true }
            let refused = rejected.filter { !skewed.contains($0) && !limited.contains($0) }
            for r in skewed {
                let id = r["id"].string ?? ""
                skewCounts[id, default: 0] += 1
                if skewCounts[id]! > Self.maxSkewRounds { throw Failure.clockSkew }
            }
            let sent = Dictionary(batch.map { ($0.op.id, $0.op) }, uniquingKeysWith: { first, _ in first })
            let ops = (res["ops"].array ?? []).compactMap(Op.init(json:))
            let purged = res["purged"].array ?? []

            let reseeded = try store.transaction {
                try checkSameAccount()
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
                if res["hasMore"].bool != true, try store.outboxCount() == 0 { try store.setMeta("reseed_device", .null) }
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
        let ops = skewed.compactMap { $0["id"].string.flatMap { sent[$0] } }
            .sorted { $0.ts != $1.ts ? $0.ts < $1.ts : opOrder($0, $1) }
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
        var held = try heldOps(store)
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
        let held = try heldOps(store)
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
            let op = Op(f)
            if isUploaded(op) { ops.append(uploadOp(op, id: newId(), device: device)) }
        }
        try store.outboxAdd(ops.sorted(by: opOrder))
        try store.setMeta("cursor", 0)
        try store.setMeta("backfill_ack", 0)
        try store.setMeta("generation", .string(generation))
        // Kept across an interrupted re-seed. The device id and every field's clock stay; only the request's
        // identity changes until the full pull finishes.
        try store.setMeta("reseed_device", .string(newId()))
    }
}

/// Ops a server limit held back, offered again on the next exchange.
func heldOps(_ store: Store) throws -> [Op] {
    (try store.meta("held_ops").array ?? []).compactMap(Op.init(json:))
}

/// A stored field the server takes back: all but an attachment's uploaded_at, which only it writes.
func isUploaded(_ op: Op) -> Bool { !(op.entity == "attachment" && op.field == "uploaded_at") }

/// A stored field sent again as an op with id. A reserved device is replaced with ours: the server refuses a batch
/// holding one. Deviation from the web app, see spec/sync.md, "Re-seed after a restore".
func uploadOp(_ op: Op, id: String, device: String) -> Op {
    var out = op
    out.id = id
    if isReservedDevice(op.device) { out.device = device }
    return out
}

/// Device ids only the server may write. A batch holding one is refused whole.
let reservedDevicePrefixes = ["agent:", "caldav:", "public:", "issues:", "calsync:", "rule:", "page:"]

public func isReservedDevice(_ device: String) -> Bool {
    device == "server" || device.hasPrefix("server:") || reservedDevicePrefixes.contains { device.hasPrefix($0) }
}
