import CryptoKit
import Foundation

/// Deterministic ids. Devices that derive an id from the same inputs write the same entity.
///
/// Mirrors ids.NameID (Go) and web/src/lib/ids.ts: the first 16 bytes of
/// SHA-256(ns + ":" + name), formatted as a version 8 UUID.
func nameId(_ ns: String, _ name: String) -> String {
    var b = Array(SHA256.hash(data: Data("\(ns):\(name)".utf8)).prefix(16))
    b[6] = (b[6] & 0x0F) | 0x80
    b[8] = (b[8] & 0x3F) | 0x80
    let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    return uuid.uuidString.lowercased()
}

/// A person's default reminder on a task.
func defaultReminderId(userId: String, taskId: String) -> String {
    nameId("default-reminder", "\(userId)\0\(taskId)")
}

/// A fresh random id for a new entity or op.
func newId() -> String { UUID().uuidString.lowercased() }

/// The completed occurrence record of a series on one day.
func occurrenceId(_ seriesId: String, _ day: Day) -> String { nameId("occurrence", "\(seriesId):\(day)") }

/// The "this occurrence only" copy of a series on one day.
func detachedId(_ seriesId: String, _ day: Day) -> String { nameId("occurrence", "\(seriesId):detach:\(day)") }
