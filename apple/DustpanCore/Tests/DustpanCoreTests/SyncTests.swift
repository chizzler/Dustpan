import Testing
@testable import DustpanCore

func remote(_ entityId: String, _ field: String, _ value: JSON, _ ts: Int64, device: String = "other") -> JSON {
    Op(id: "\(entityId)-\(field)-\(ts)", entity: "task", entityId: entityId, field: field, value: value,
       ts: ts, device: device).json
}

/// Answers sync requests from a list of prepared responses.
final class FakeServer: SyncServer {
    var responses: [(JSON) throws -> JSON]
    var requests: [JSON] = []
    var encrypted = false
    var userId = "me"
    var accountKey: JSON?
    var generation = "g1"
    /// Permanent deletes asked for, in order.
    var purges: [TrashItem.Target] = []
    /// Runs on each purge: throw to fail it.
    var onPurge: (TrashItem.Target) throws -> Void = { _ in }

    init(_ responses: [JSON], encrypted: Bool = false, userId: String = "me", accountKey: JSON? = nil) {
        self.responses = responses.map { r in { _ in r } }
        self.encrypted = encrypted
        (self.userId, self.accountKey) = (userId, accountKey)
    }

    init(planned: [(JSON) throws -> JSON], userId: String = "me", accountKey: JSON? = nil) {
        responses = planned
        (self.userId, self.accountKey) = (userId, accountKey)
    }

    func me() async throws -> JSON {
        ["user": ["id": .string(userId)], "encryption": ["enabled": .bool(encrypted)]]
    }

    func purge(entity: String, id: String) async throws {
        let target = TrashItem.Target(entity: entity, id: id)
        purges.append(target)
        try onPurge(target)
    }

    func sync(_ body: JSON) async throws -> JSON {
        requests.append(body)
        let planned = responses.isEmpty ? [:] : try responses.removeFirst()(body)
        // Like a real server, a new generation sticks once announced.
        generation = planned["generation"].string ?? generation
        var res: [String: JSON] = ["ops": [], "cursor": body["cursor"], "hasMore": false, "serverTime": 1_000,
                                   "generation": .string(generation)]
        res.merge(planned.object ?? [:]) { _, new in new }
        return .object(res)
    }
}

@Suite struct SyncTests {
    let store: Store

    init() throws { store = try memoryStore() }

    @discardableResult
    func runSync(_ responses: JSON..., encrypted: Bool = false) async throws -> (FakeServer, Int) {
        let server = FakeServer(responses, encrypted: encrypted)
        let result = try await Syncer(store: store, server: server).run()
        return (server, result.received)
    }

    @discardableResult
    func queueLocal(_ entityId: String, _ field: String, _ value: JSON, _ ts: Int64) throws -> Op {
        var local = Op(json: remote(entityId, field, value, ts, device: try store.device()))!
        local.id = "local-\(field)"
        try store.apply(local)
        try store.outboxAdd([local])
        return local
    }

    @Test func pagesUntilNoMore() async throws {
        let (server, received) = try await runSync(
            ["ops": [remote("t1", "title", "A", 1)], "cursor": 1, "hasMore": true],
            ["ops": [remote("t2", "title", "B", 2)], "cursor": 2])
        #expect(received == 2)
        #expect(server.requests.map { $0["cursor"] } == [0, 1])
        #expect(try store.meta("cursor") == 2)
        #expect(Set(try store.rows("task").keys) == ["t1", "t2"])
    }

    @Test func deviceIdIsStableAndSent() async throws {
        let (a, _) = try await runSync()
        let (b, _) = try await runSync()
        #expect(a.requests[0]["device"] == b.requests[0]["device"])
        #expect(a.requests[0]["device"].string != nil)
    }

    @Test func purgeMarkerDeletesEntity() async throws {
        try await runSync(["ops": [remote("t1", "title", "A", 1)], "cursor": 1])
        try await runSync(["purged": [["entity": "task", "entityId": "t1"]], "cursor": 2])
        #expect(try store.rows("task").isEmpty)
    }

    @Test func backfillSeqIsEchoed() async throws {
        let (server, _) = try await runSync(["backfillSeq": 7, "hasMore": true], [:])
        #expect(server.requests.map { $0["backfillAck"] } == [0, 7])
    }

    @Test func encryptedAccountIsRefused() async throws {
        await #expect(throws: Syncer.Failure.self) { _ = try await runSync(encrypted: true) }
    }

    @Test func generationChangeReseedsWithStoredClocks() async throws {
        try await runSync(["ops": [remote("t1", "title", "A", 5, device: "phone"),
                                   remote("t1", "priority", 2, 6, device: "server:abc")], "cursor": 9])
        let (server, _) = try await runSync(["generation": "g2", "cursor": 9], ["cursor": 3])
        #expect(server.requests[1]["cursor"] == 0)
        let sent = Dictionary(uniqueKeysWithValues: (server.requests[1]["ops"].array ?? []).map { ($0["field"].string!, $0) })
        #expect(sent["title"]?["ts"] == 5 && sent["title"]?["device"] == "phone")
        // A reserved device would get the batch refused; ours replaces it.
        #expect(sent["priority"]?["ts"] == 6)
        let device = try store.meta("device")
        #expect(sent["priority"]?["device"] == device)
        #expect(try store.meta("generation") == "g2")
        #expect(try store.outboxCount() == 0)
    }

    @Test func reseedSkipsOtherAuthorsComments() async throws {
        func comment(_ id: String, _ author: String) -> JSON {
            ["id": .string(id), "entity": "comment", "entityId": .string(id), "field": "author_id",
             "value": .string(author), "ts": 1, "device": "x"]
        }
        try await runSync(["ops": [comment("c1", "me"), comment("c2", "someone")], "cursor": 2])
        let (server, _) = try await runSync(["generation": "g2"], [:])
        #expect(server.requests[1]["ops"].array?.map { $0["entityId"] } == ["c1"])
    }

    @Test func refusedOpGivesWayToTheServersValue() async throws {
        try queueLocal("t1", "title", "Mine", 50)
        let serverValue = remote("t1", "title", "Theirs", 10, device: "server:x")
        let server = FakeServer([["rejected": [["id": "local-title", "reason": "forbidden"]], "ops": [serverValue]]])
        let result = try await Syncer(store: store, server: server).run()
        #expect(result.refused == 1)
        #expect(try store.rows("task")["t1"]?["title"] == "Theirs")
        #expect(try store.outboxCount() == 0)
    }

    @Test func refusalKeepsANewerLocalEdit() async throws {
        try queueLocal("t1", "title", "First", 50)
        let store = store
        let server = FakeServer(planned: [{ _ in
            // The user edited again while the request was out.
            var newer = Op(json: remote("t1", "title", "Second", 60, device: try! store.device()))!
            newer.id = "newer"
            try! store.apply(newer)
            return ["rejected": [["id": "local-title", "reason": "forbidden"]]]
        }])
        _ = try await Syncer(store: store, server: server).run()
        #expect(try store.rows("task")["t1"]?["title"] == "Second")
    }

    @Test func clockSkewRestampsAndResendsWithTheSameId() async throws {
        let far: Int64 = 1_000 + 10 * 60_000
        try queueLocal("t1", "title", "A", far)
        try queueLocal("t1", "priority", 1, far)
        try store.setMeta("clock_last", .int(far))
        let server = FakeServer([["rejected": [["id": "local-title", "reason": "clock_skew", "serverTime": 1_000],
                                               ["id": "local-priority", "reason": "clock_skew", "serverTime": 1_000]]]])
        _ = try await Syncer(store: store, server: server).run()
        let resent = server.requests[1]["ops"].array ?? []
        #expect(Set(resent.compactMap { $0["id"].string }) == ["local-title", "local-priority"])
        #expect(Set(resent.compactMap { $0["ts"].int }).count == 1)
        let ts = try #require(resent.first?["ts"].int)
        #expect(ts < far)
        #expect(try store.rows("task")["t1"]?.clocks["title"]?.ts == ts)
    }

    @Test func endlessClockSkewIsAnError() async throws {
        try queueLocal("t1", "title", "A", 5)
        let refuse: JSON = ["rejected": [["id": "local-title", "reason": "clock_skew"]]]
        await #expect(throws: Syncer.Failure.self) { _ = try await runSync(refuse, refuse, refuse, refuse, refuse) }
    }

    @Test func limitedOpsAreHeldAndOfferedNextTime() async throws {
        try queueLocal("t1", "title", "A", 5)
        let server = FakeServer([["rejected": [["id": "local-title", "reason": "limit_ops_hour"]]]])
        let result = try await Syncer(store: store, server: server).run()
        #expect(result.held == 1)
        #expect(try store.outboxCount() == 0)
        #expect(try store.rows("task")["t1"]?["title"] == "A")
        let (again, _) = try await runSync()
        #expect(again.requests[0]["ops"].array?.map { $0["id"] } == ["local-title"])
    }

    @Test func clockSkewFeatureIsAnnounced() async throws {
        let (server, _) = try await runSync()
        #expect(server.requests[0]["features"].array?.contains("clock_skew") == true)
    }

    @Test func restoreDownloadsOwnFieldsMissingAfterAPurge() async throws {
        let device = try store.transaction { try store.device() }
        let own = remote("t1", "title", "Back in the archive", 5, device: device)
        try await runSync(["ops": [own], "cursor": 9])
        try store.purge(entity: "task", id: "t1")
        let server = FakeServer(planned: [
            { _ in ["generation": "g2"] },
            // The real server skips ops authored by the request's device.
            { body in ["ops": body["device"].string == device ? [] : [own], "cursor": 1] },
        ])
        _ = try await Syncer(store: store, server: server).run()
        #expect(server.requests[1]["device"].string != device)
        let task = try #require(try store.rows("task")["t1"])
        #expect(task["title"] == "Back in the archive")
        #expect(try store.device() == device && task.clocks["title"]?.device == device)
        #expect(try store.meta("reseed_device").isNull)
        let (again, _) = try await runSync()
        #expect(again.requests[0]["device"].string == device)
    }

    @Test func recoveryIdentitySurvivesInterruptionAndPaging() async throws {
        try await runSync(["ops": [remote("t1", "title", "Keep", 5)], "cursor": 9])
        let device = try store.device()
        let lost = FakeServer(planned: [{ _ in ["generation": "g2"] }, { _ in throw ApiError.offline("lost acknowledgement") }])
        await #expect(throws: ApiError.self) { try await Syncer(store: store, server: lost).run() }
        let replay = try #require(try store.meta("reseed_device").string)
        #expect(replay != device)
        #expect(try store.outboxCount() > 0)
        let resumed = FakeServer([["hasMore": true, "cursor": 1], ["cursor": 2]])
        resumed.generation = "g2"
        _ = try await Syncer(store: store, server: resumed).run()
        #expect(resumed.requests.map { $0["device"].string } == [replay, replay])
        #expect(try store.device() == device)
        #expect(try store.meta("reseed_device").isNull)
        #expect(try store.outboxCount() == 0)
    }

    @Test func reservedDevices() {
        for device in ["server", "server:1", "agent:x", "caldav:x", "public:x", "rule:x", "page:x"] {
            #expect(isReservedDevice(device), "\(device)")
        }
        for device in ["3c54-abcd", "assistant:x", "serverless"] {
            #expect(!isReservedDevice(device), "\(device)")
        }
    }
}
