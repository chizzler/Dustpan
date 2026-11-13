import CryptoKit
import Foundation

// Standalone data meeting an OpenTodo account, and switching accounts. See spec/sync.md, "Standalone use and
// connecting later" and "Account switching and disconnected deletion". A port of the desktop's sync.py.

/// Store meta: bumped whenever local data is adopted, migrated or replaced for an account.
/// A sync started before the bump sends and keeps nothing after it.
public let accountEpochKey = "account_epoch"

/// Parents and tasks upload before reminders, comments, attachments and time entries.
let entityOrder = ["project", "section", "field", "label", "view", "task", "reminder", "comment", "attachment",
                   "time_entry", "user_prefs", "project_prefs", "review"]
let leadFields = ["project_id", "task_id", "user_id", "author_id", "series_id", "recurrence", "kind", "started_at"]
/// Entities whose fields go in one request: the server checks them together.
let batchWhole: Set = ["reminder", "comment", "attachment", "time_entry"]

/// The upload order: entity kind, entity, then the fields the server checks first.
func opOrder(_ a: Op, _ b: Op) -> Bool {
    func rank(_ list: [String], _ name: String) -> Int { list.firstIndex(of: name) ?? list.count }
    let ka = (rank(entityOrder, a.entity), a.entity, a.entityId, rank(leadFields, a.field), a.field)
    let kb = (rank(entityOrder, b.entity), b.entity, b.entityId, rank(leadFields, b.field), b.field)
    return ka < kb
}

/// The server and a digest of the token: a new token for the same account needs no /me.
func accountKey(url: URL, token: String) -> JSON {
    let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    return [.string(url.absoluteString), .string(digest)]
}

/// Ask the server who the token belongs to, refusing accounts this client can't handle. Returns the user id and the
/// account key.
public func verifyAccount(_ server: any SyncServer) async throws -> (userId: String, key: JSON?) {
    let me = try await server.me()
    if me["encryption"]["enabled"].bool == true {
        throw Syncer.Failure.unsupportedAccount("end-to-end encrypted accounts are not supported yet")
    }
    guard let id = me["user"]["id"].string else { throw Syncer.Failure.badResponse("/me has no user id") }
    return (id, server.accountKey)
}

private func bumpEpoch(_ store: Store) throws {
    try store.setMeta(accountEpochKey, .int((try store.meta(accountEpochKey).int ?? 0) + 1))
}

private extension Op {
    init(_ f: Store.Field, id: String = "") {
        self.init(id: id, entity: f.entity, entityId: f.entityId, field: f.field, value: f.value, ts: f.ts, device: f.device)
    }

    var key: [String] { [entity, entityId, field] }
}

/// The standalone actor becomes userId: completions, authored rows, and default reminders' ids.
private func rewriteLocal(_ op: Op, _ userId: String, _ reminders: [String: String]) -> Op {
    var out = op
    if op.entity == "reminder", let id = reminders[op.entityId] { out.entityId = id }
    let actor = op.entity == "task" ? "completed_by" : Syncer.authored[op.entity]
    if op.field == actor, op.value.string == localUser { out.value = .string(userId) }
    return out
}

/// Standalone data joins userId's account, before its first sync, in one transaction. The fields are queued once
/// each, in upload order, for the first exchange to send.
public func adoptStandalone(_ store: Store, userId: String, accountKey key: JSON? = nil) throws {
    try store.transaction {
        if let stored = try store.meta("user_id").string, stored != localUser {
            throw Syncer.Failure.accountChanged("this device was connected to an account in the meantime")
        }
        try bumpEpoch(store)
        let device = try store.device()
        let fields = try store.allFields()
        let queued = try store.outboxBatch(limit: try store.outboxCount()).map(\.op)
        let held = (try store.meta("held_ops").array ?? []).compactMap(Op.init(json:))
        if !fields.isEmpty || !queued.isEmpty || !held.isEmpty {
            var taskIds = Set(fields.filter { $0.entity == "task" }.map(\.entityId))
            taskIds.formUnion(fields.filter { $0.entity == "reminder" && $0.field == "task_id" }.compactMap(\.value.string))
            let reminderIds = Set(fields.filter { $0.entity == "reminder" }.map(\.entityId))
            var reminderMap: [String: String] = [:]
            for taskId in taskIds {
                let old = defaultReminderId(userId: localUser, taskId: taskId)
                let new = defaultReminderId(userId: userId, taskId: taskId)
                if reminderIds.contains(old), old != new { reminderMap[old] = new }
            }
            let rewritten = fields.map { rewriteLocal(Op($0), userId, reminderMap) }
            if rewritten != fields.map({ Op($0) }) {
                try store.clearFields()
                for op in rewritten { try store.apply(op) }
            }
            if !reminderMap.isEmpty, let notified = try store.meta("notified").object {
                try store.setMeta("notified", .object(Dictionary(notified.map { (reminderMap[$0.key] ?? $0.key, $0.value) },
                                                                 uniquingKeysWith: { _, last in last })))
            }
            var knownIds: [[String]: String] = [:]
            for op in queued + held { knownIds[rewriteLocal(op, userId, reminderMap).key] = op.id }

            if try store.meta("generation").isNull {
                // Never synced: send each field once, as it stands, whatever edits led to it.
                let ops = try store.allFields().filter { !($0.entity == "attachment" && $0.field == "uploaded_at") }.map { f in
                    var op = Op(f, id: knownIds[[f.entity, f.entityId, f.field]] ?? newId())
                    if isReservedDevice(f.device) { op.device = device }
                    return op
                }
                try store.clearOutbox()
                try store.outboxAdd(ops.sorted(by: opOrder))
                try store.setMeta("held_ops", [])
                try store.setMeta("cursor", 0)
                try store.setMeta("backfill_ack", 0)
            } else {
                try store.clearOutbox()
                try store.outboxAdd(queued.map { rewriteLocal($0, userId, reminderMap) })
                if !held.isEmpty { try store.setMeta("held_ops", .array(held.map { rewriteLocal($0, userId, reminderMap).json })) }
            }
        }
        try store.setMeta("user_id", .string(userId))
        if let key { try store.setMeta("account_key", key) }
    }
}

private let nullableRefs: Set<[String]> = [
    ["project", "parent_id"], ["note", "project_id"], ["rule", "project_id"], ["task", "project_id"],
    ["task", "parent_id"], ["task", "section_id"], ["task", "series_id"], ["comment", "parent_id"],
]
private let requiredRefs: Set<[String]> = [
    ["section", "project_id"], ["field", "project_id"], ["reminder", "task_id"], ["comment", "task_id"],
    ["time_entry", "task_id"],
]
private let listRefs: Set<[String]> = [
    ["task", "labels"], ["note", "labels"], ["task", "blocked_by"], ["label", "manual_order"], ["view", "panels"],
    ["view", "manual_order"], ["slot", "task_ids"],
]

/// Upload this device's data into another account: every entity gets a fresh id, so the two accounts never claim the
/// same one, even on one server. Items waiting for a server purge belong to the old account and are deleted here.
public func migrateAccount(_ store: Store, userId: String, accountKey key: JSON? = nil) throws {
    try store.transaction {
        try bumpEpoch(store)
        for target in try expandPurge(store, try pendingList(store)) { try store.purge(entity: target.entity, id: target.id) }
        let oldUser = try store.meta("user_id").string ?? localUser
        let mine = [oldUser, localUser]
        let device = try store.device()
        let fields = try store.allFields()
        var rows: [String: [String: [String: JSON]]] = [:]
        for f in fields { rows[f.entity, default: [:]][f.entityId, default: [:]][f.field] = f.value }

        let skipEntities: Set = ["attachment"]
        var skipRows: Set<[String]> = []
        for (entity, author) in Syncer.authored where !skipEntities.contains(entity) {
            for (id, values) in rows[entity] ?? [:] where !mine.contains(values[author]?.string ?? "") {
                skipRows.insert([entity, id])
            }
        }

        var ids: [String: String] = [:]
        for (entity, byId) in rows
        where !["user_prefs", "review", "project_prefs", "task", "reminder"].contains(entity) && !skipEntities.contains(entity) {
            for id in byId.keys where !skipRows.contains([entity, id]) { ids[id] = newId() }
        }
        let tasks = rows["task"] ?? [:]
        for (id, values) in tasks where !(values["series_id"]?.isTruthy ?? false) { ids[id] = newId() }
        for (id, values) in tasks where ids[id] == nil {
            var mapped: String?
            if let oldSeries = values["series_id"]?.string, let newSeries = ids[oldSeries] {
                let days = [values["occurrence_date"]?.string, values["due"]?["date"].string].compactMap { $0.flatMap(Day.init) }
                for day in days {
                    if id == occurrenceId(oldSeries, day) { mapped = occurrenceId(newSeries, day); break }
                    if id == detachedId(oldSeries, day) { mapped = detachedId(newSeries, day); break }
                }
            }
            ids[id] = mapped ?? newId()
        }
        for (id, values) in rows["reminder"] ?? [:] {
            guard let oldTask = values["task_id"]?.string, let newTask = ids[oldTask] else {
                skipRows.insert(["reminder", id])
                continue
            }
            let isDefault = mine.contains { defaultReminderId(userId: $0, taskId: oldTask) == id }
            ids[id] = isDefault ? defaultReminderId(userId: userId, taskId: newTask) : newId()
        }
        for entity in ["comment", "time_entry"] {
            for (id, values) in rows[entity] ?? [:] where values["task_id"]?.string.flatMap({ ids[$0] }) == nil {
                skipRows.insert([entity, id])
                ids[id] = nil
            }
        }

        func refs(_ text: String, _ map: (Substring, Substring) -> String?) -> String {
            text.split(separator: ",").compactMap { entry in
                guard let colon = entry.firstIndex(of: ":") else { return nil }
                return map(entry[..<colon], entry[entry.index(after: colon)...])
            }.joined(separator: ",")
        }

        var ops: [Op] = []
        try store.clearFields()
        for f in fields where !skipEntities.contains(f.entity) && !skipRows.contains([f.entity, f.entityId]) {
            let entityId: String
            if ["user_prefs", "review"].contains(f.entity) {
                entityId = f.entityId
            } else if let mapped = ids[f.entityId] {
                entityId = mapped
            } else {
                continue
            }
            var field = f.field, value = f.value
            let pair = [f.entity, f.field]
            if f.entity == "task", field.hasPrefix("fields.") {
                guard let def = ids[String(field.dropFirst("fields.".count))] else { continue }
                field = "fields." + def
            } else if nullableRefs.contains(pair) {
                value = value.string.flatMap { $0.isEmpty ? nil : ids[$0] }.map(JSON.string) ?? .null
            } else if requiredRefs.contains(pair) {
                guard let mapped = value.string.flatMap({ ids[$0] }) else { continue }
                value = .string(mapped)
            } else if listRefs.contains(pair), let list = value.array {
                value = .array(list.compactMap { $0.string.flatMap { ids[$0] }.map(JSON.string) })
            } else if pair == ["task", "split_from"] {
                value = value["series"].string.flatMap { ids[$0] }.map { ["series": .string($0), "date": value["date"]] } ?? .null
            } else if pair == ["task", "completed_by"] {
                value = value.isNull ? .null : .string(userId)
            } else if pair == ["task", "assignee_id"] {
                value = value.string.map(mine.contains) == true ? .string(userId) : .null
            } else if [["task", "rotation"], ["task", "note_mentions"], ["comment", "mentions"]].contains(pair) {
                value = []
            } else if field == "workspace_id" {
                value = .null
            } else if field == Syncer.authored[f.entity] {
                value = .string(userId)
            } else if pair == ["frame", "source"], let text = value.string, let colon = text.firstIndex(of: ":") {
                value = .string(ids[String(text[text.index(after: colon)...])].map { "\(text[..<colon]):\($0)" } ?? "")
            } else if pair == ["user_prefs", "favourites"], let text = value.string, !text.isEmpty {
                value = .string(refs(text) { kind, ref in ids[String(ref)].map { "\(kind):\($0)" } })
            } else if f.entity == "review", ["focus", "slots"].contains(field), let text = value.string, !text.isEmpty {
                value = .string(text.split(separator: ",").compactMap { ids[String($0)] }.joined(separator: ","))
            } else if pair == ["review", "focus_slots"], let text = value.string, !text.isEmpty {
                value = .string(refs(text) { slot, ref in ids[String(ref)].map { "\(slot):\($0)" } })
            }
            let op = Op(id: newId(), entity: f.entity, entityId: entityId, field: field, value: value, ts: f.ts,
                        device: isReservedDevice(f.device) ? device : f.device)
            try store.apply(op)
            ops.append(op)
        }
        try store.clearOutbox()
        try store.outboxAdd(ops.sorted(by: opOrder))

        if let folded = try store.meta(foldedTasksKey).array {
            try store.setMeta(foldedTasksKey, .array(folded.compactMap { $0.string.flatMap { ids[$0] }.map(JSON.string) }))
        }
        if let cleared = try store.meta(clearedSubtasksKey).object {
            var out: [String: JSON] = [:]
            for (id, entry) in cleared {
                guard let newId = ids[id], let pair = entry.array, pair.count == 2 else { continue }
                out[newId] = [pair[0], pair[1].string.flatMap { ids[$0] }.map(JSON.string) ?? .null]
            }
            try store.setMeta(clearedSubtasksKey, .object(out))
        }
        if let recent = try store.meta(recentLabelsKey).array {
            try store.setMeta(recentLabelsKey, .array(recent.compactMap { $0.string.flatMap { ids[$0] }.map(JSON.string) }))
        }
        if let notified = try store.meta("notified").object {
            try store.setMeta("notified", .object(Dictionary(uniqueKeysWithValues: notified.compactMap { id, at in
                ids[id].map { ($0, at) } })))
        }
        let reset: [(String, JSON)] = [
            ("cursor", 0), ("backfill_ack", 0), ("generation", .null), ("reseed_device", .null), ("held_ops", []),
            (pendingPurgesKey, []), (trashRetentionKey, .null), ("user_id", .string(userId)),
        ]
        for (name, value) in reset { try store.setMeta(name, value) }
        if let key { try store.setMeta("account_key", key) }
    }
}

/// Replace this device's data with userId's account: everything synced goes, and the next sync pulls it all.
/// The device id stays.
public func resetForAccount(_ store: Store, userId: String, accountKey key: JSON? = nil) throws {
    try store.transaction {
        try bumpEpoch(store)
        try store.clearFields()
        try store.clearOutbox()
        let reset: [(String, JSON)] = [
            ("cursor", 0), ("backfill_ack", 0), ("generation", .null), ("reseed_device", .null), ("held_ops", []),
            (pendingPurgesKey, []), (trashRetentionKey, .null), ("notified", .null), (foldedTasksKey, []),
            (clearedSubtasksKey, [:]), (recentLabelsKey, []), ("user_id", .string(userId)),
        ]
        for (name, value) in reset { try store.setMeta(name, value) }
        if let key { try store.setMeta("account_key", key) }
    }
}
