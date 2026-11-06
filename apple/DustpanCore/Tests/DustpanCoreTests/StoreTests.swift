import Testing
@testable import DustpanCore

func op(_ field: String, _ value: JSON, _ ts: Int64, device: String = "d1", entity: String = "task",
        id entityId: String = "t1") -> Op {
    Op(id: "\(entityId)-\(field)-\(ts)-\(device)", entity: entity, entityId: entityId, field: field,
       value: value, ts: ts, device: device)
}

func memoryStore() throws -> Store { try Store(path: ":memory:") }

@Suite struct WinnerRule {
    @Test func newerTimestampWins() {
        #expect(wins(2, "a", 1, "z"))
        #expect(!wins(1, "z", 2, "a"))
    }

    @Test func equalTimestampBreaksOnDevice() {
        #expect(wins(5, "b", 5, "a"))
        #expect(!wins(5, "a", 5, "b"))
        #expect(!wins(5, "a", 5, "a"))
    }

    @Test func devicesCompareAsBytes() {
        // Unicode-aware comparison would put "é" (U+00E9) before "z"; bytes put it after.
        #expect(wins(5, "é", 5, "z"))
    }
}

@Suite struct StoreTests {
    @Test func applyKeepsTheWinnerInAnyOrder() throws {
        let ops = [op("title", "old", 1), op("title", "new", 3), op("title", "mid", 2)]
        for order in [ops, ops.reversed()] {
            let store = try memoryStore()
            for o in order { try store.apply(o) }
            #expect(try store.rows("task")["t1"]?["title"] == "new")
        }
    }

    @Test func applyIsIdempotent() throws {
        let store = try memoryStore()
        #expect(try store.apply(op("title", "a", 1)))
        #expect(try !store.apply(op("title", "a", 1)))
    }

    @Test func fieldsMergeIndependently() throws {
        let store = try memoryStore()
        try store.apply(op("title", "a", 5, device: "d1"))
        try store.apply(op("priority", 1, 2, device: "d2"))
        let row = try #require(try store.rows("task")["t1"])
        #expect(row["title"] == "a" && row["priority"] == 1)
        #expect(row.clocks["priority"]?.device == "d2")
    }

    @Test func purgeRemovesFieldsAndQueuedOps() throws {
        let store = try memoryStore()
        try store.apply(op("title", "a", 1))
        try store.outboxAdd([op("title", "b", 2)])
        try store.purge(entity: "task", id: "t1")
        #expect(try store.rows("task").isEmpty)
        #expect(try store.outboxCount() == 0)
    }

    @Test func metaRoundTripsJSON() throws {
        let store = try memoryStore()
        try store.setMeta("cursor", 42)
        #expect(try store.meta("cursor") == 42)
        #expect(try store.meta("missing") == .null)
    }

    @Test func valuesRoundTrip() throws {
        let store = try memoryStore()
        let value: JSON = ["date": "2026-11-04", "time": "09:00", "tz": nil, "n": 1.5, "flags": [true, false, 3]]
        try store.apply(op("due", value, 1))
        #expect(try store.rows("task")["t1"]?["due"] == value)
    }

    @Test func outboxKeepsOrderAndOps() throws {
        let store = try memoryStore()
        let ops = [op("title", "a", 1), op("priority", 2, 2)]
        try store.outboxAdd(ops)
        #expect(try store.outboxBatch(limit: 10).map(\.op) == ops)
        try store.outboxRemove(try store.outboxBatch(limit: 1).map(\.seq))
        #expect(try store.outboxBatch(limit: 10).map(\.op) == [ops[1]])
    }
}

final class FakeTime: @unchecked Sendable {
    var now: Int64 = 1_000_000
}

@Suite struct ClockTests {
    let store: Store
    let time = FakeTime()
    let clock: HybridClock

    init() throws {
        store = try memoryStore()
        clock = HybridClock(store: store, now: { [time] in time.now })
    }

    @Test func stampsStrictlyIncreaseWhenWallClockGoesBack() throws {
        let first = try clock.stamp()
        time.now -= 10_000
        #expect(try clock.stamp() > first)
    }

    @Test func receiveMovesPastSeenTimestamps() throws {
        try clock.receive(time.now + 500)
        #expect(try clock.stamp() > time.now + 500)
    }

    @Test func followsServerOnlyBeyondTwoSeconds() throws {
        try clock.followServer(time.now + 1_500)
        #expect(try clock.offset() == 0)
        try clock.followServer(time.now + 60_000)
        #expect(try clock.offset() == 60_000)
    }

    @Test func farFutureSeedComesBackToServerTime() throws {
        try clock.receive(time.now + 10 * 60_000)
        try clock.followServer(time.now)
        #expect(try clock.last() == time.now)
    }

    @Test func refusalsInOneExchangeKeepEditsInOrder() throws {
        // OpenTodo #651: two batches refused in turn must not stamp the later edit first.
        let server = time.now
        time.now += 2 * 3_600_000
        _ = try clock.stamp()
        _ = try clock.stamp()
        try clock.refused(server)
        let first = try clock.stamp()
        try clock.refused(server)
        let second = try clock.stamp()
        #expect(first <= server + 5 * 60_000)
        #expect(second > first)
    }
}
