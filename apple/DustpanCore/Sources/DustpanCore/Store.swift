import Foundation
import SQLite3

/// Local copy of the synced state: one last-writer-wins register per field.
/// The same schema as the desktop client. See spec/sync.md, "Local store".
public final class Store {
    static let schema = """
        CREATE TABLE IF NOT EXISTS fields (
            entity    TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            field     TEXT NOT NULL,
            value     TEXT NOT NULL,
            ts        INTEGER NOT NULL,
            device    TEXT NOT NULL,
            PRIMARY KEY (entity, entity_id, field)
        ) WITHOUT ROWID;

        CREATE TABLE IF NOT EXISTS outbox (
            seq       INTEGER PRIMARY KEY AUTOINCREMENT,
            entity    TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            op        TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """

    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw StoreError(message: "can't open \(path): \(message)")
        }
        db = handle
        sqlite3_busy_timeout(db, 10_000)
        try exec("PRAGMA journal_mode=WAL")
        try exec(Self.schema)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close(db)
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: meta

    public func meta(_ key: String) throws -> JSON {
        try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { try JSON(parsing: $0.text(0)) }.first ?? .null
    }

    public func setMeta(_ key: String, _ value: JSON) throws {
        try run("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                [.text(key), .text(value.text)])
    }

    /// This device's id, created on first use.
    public func device() throws -> String {
        if let device = try meta("device").string { return device }
        let device = UUID().uuidString.lowercased()
        try setMeta("device", .string(device))
        return device
    }

    // MARK: fields

    /// Store op if it wins over the current value. Returns true when it did.
    @discardableResult
    public func apply(_ op: Op) throws -> Bool {
        let current = try query("SELECT ts, device FROM fields WHERE entity = ? AND entity_id = ? AND field = ?",
                                [.text(op.entity), .text(op.entityId), .text(op.field)]) {
            FieldClock(ts: $0.int(0), device: $0.text(1))
        }.first
        if let current, !wins(op.ts, op.device, current.ts, current.device) { return false }
        try run("INSERT OR REPLACE INTO fields (entity, entity_id, field, value, ts, device) VALUES (?, ?, ?, ?, ?, ?)",
                [.text(op.entity), .text(op.entityId), .text(op.field), .text(op.value.text), .int(op.ts), .text(op.device)])
        return true
    }

    /// Drop a field while it still holds op, so any value the server sends wins.
    public func forget(_ op: Op) throws {
        try run("DELETE FROM fields WHERE entity = ? AND entity_id = ? AND field = ? AND ts = ? AND device = ?",
                [.text(op.entity), .text(op.entityId), .text(op.field), .int(op.ts), .text(op.device)])
    }

    /// Move a field's clock to ts while it still holds op.
    public func restamp(_ op: Op, to ts: Int64) throws {
        try run("UPDATE fields SET ts = ? WHERE entity = ? AND entity_id = ? AND field = ? AND ts = ? AND device = ?",
                [.int(ts), .text(op.entity), .text(op.entityId), .text(op.field), .int(op.ts), .text(op.device)])
    }

    /// Remove an entity the server purged, with any queued ops for it.
    public func purge(entity: String, id: String) throws {
        try run("DELETE FROM fields WHERE entity = ? AND entity_id = ?", [.text(entity), .text(id)])
        try run("DELETE FROM outbox WHERE entity = ? AND entity_id = ?", [.text(entity), .text(id)])
    }

    /// Every field gone: data replaced by another account's, or re-keyed for it.
    func clearFields() throws { try run("DELETE FROM fields", []) }

    func clearOutbox() throws { try run("DELETE FROM outbox", []) }

    public struct Field {
        public let entity, entityId, field: String
        public let value: JSON
        public let ts: Int64
        public let device: String
    }

    public func allFields() throws -> [Field] {
        try query("SELECT entity, entity_id, field, value, ts, device FROM fields", []) {
            Field(entity: $0.text(0), entityId: $0.text(1), field: $0.text(2),
                  value: try JSON(parsing: $0.text(3)), ts: $0.int(4), device: $0.text(5))
        }
    }

    /// Fold every field of one entity kind into rows, keyed by id.
    public func rows(_ entity: String) throws -> [String: Row] {
        var rows: [String: Row] = [:]
        try each("SELECT entity_id, field, value, ts, device FROM fields WHERE entity = ?", [.text(entity)]) { r in
            let id = r.text(0), name = r.text(1)
            rows[id, default: Row(id: id)].values[name] = try JSON(parsing: r.text(2))
            rows[id]!.clocks[name] = FieldClock(ts: r.int(3), device: r.text(4))
        }
        return rows
    }

    // MARK: outbox

    public func outboxAdd(_ ops: [Op]) throws {
        for op in ops {
            try run("INSERT INTO outbox (entity, entity_id, op) VALUES (?, ?, ?)",
                    [.text(op.entity), .text(op.entityId), .text(op.json.text)])
        }
    }

    /// The oldest queued ops, as (seq, op) pairs.
    public func outboxBatch(limit: Int) throws -> [(seq: Int64, op: Op)] {
        try query("SELECT seq, op FROM outbox ORDER BY seq LIMIT ?", [.int(Int64(limit))]) { r in
            guard let op = Op(json: try JSON(parsing: r.text(1))) else {
                throw StoreError(message: "outbox row \(r.int(0)) is not an op")
            }
            return (r.int(0), op)
        }
    }

    public func outboxRemove(_ seqs: [Int64]) throws {
        for seq in seqs { try run("DELETE FROM outbox WHERE seq = ?", [.int(seq)]) }
    }

    public func outboxCount() throws -> Int {
        try query("SELECT count(*) FROM outbox", []) { Int($0.int(0)) }.first ?? 0
    }

    // MARK: SQLite

    enum Value {
        case text(String)
        case int(Int64)
    }

    struct Cursor {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func run(_ sql: String, _ values: [Value]) throws {
        try each(sql, values) { _ in }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ row: (Cursor) throws -> T) throws -> [T] {
        var out: [T] = []
        try each(sql, values) { out.append(try row($0)) }
        return out
    }

    private func each(_ sql: String, _ values: [Value], _ row: (Cursor) throws -> Void) throws {
        let statement = try prepared(sql)
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .int(let n): sqlite3_bind_int64(statement, index, n)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(Cursor(statement: statement))
            case SQLITE_DONE: return
            default: throw error()
            }
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] { return statement }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        statements[sql] = statement
        return statement
    }

    private func error() -> StoreError {
        StoreError(message: String(cString: sqlite3_errmsg(db)))
    }
}

public struct StoreError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "store: \(message)" }
}

/// The winner rule: newer timestamp, then greater device id (compared as bytes).
public func wins(_ ts: Int64, _ device: String, _ curTs: Int64, _ curDevice: String) -> Bool {
    ts > curTs || (ts == curTs && curDevice.utf8.lexicographicallyPrecedes(device.utf8))
}

public struct FieldClock: Hashable, Sendable {
    public var ts: Int64
    public var device: String
}

/// One entity folded from its fields.
public struct Row: Hashable, Identifiable, Sendable {
    public let id: String
    public var values: [String: JSON] = [:]
    public var clocks: [String: FieldClock] = [:]

    public init(id: String, values: [String: JSON] = [:]) {
        self.id = id
        self.values = values
    }

    /// The field's value, or null when it's missing.
    public subscript(name: String) -> JSON { values[name] ?? .null }
}

/// One field write, as the sync API sends it.
public struct Op: Hashable, Sendable {
    public var id, entity, entityId, field: String
    public var value: JSON
    public var ts: Int64
    public var device: String

    public init(id: String, entity: String, entityId: String, field: String, value: JSON, ts: Int64, device: String) {
        (self.id, self.entity, self.entityId, self.field, self.value, self.ts, self.device) =
            (id, entity, entityId, field, value, ts, device)
    }

    public init?(json: JSON) {
        guard let id = json["id"].string, let entity = json["entity"].string, let entityId = json["entityId"].string,
              let field = json["field"].string, let ts = json["ts"].int, let device = json["device"].string
        else { return nil }
        self.init(id: id, entity: entity, entityId: entityId, field: field, value: json["value"], ts: ts, device: device)
    }

    public var json: JSON {
        ["id": .string(id), "entity": .string(entity), "entityId": .string(entityId), "field": .string(field),
         "value": value, "ts": .int(ts), "device": .string(device)]
    }
}
