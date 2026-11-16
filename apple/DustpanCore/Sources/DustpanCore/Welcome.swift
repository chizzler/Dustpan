import Foundation

private let welcomeCompletedKey = "mac_welcome_completed"

/// First-launch presentation is local to this profile. An existing profile upgrades without onboarding,
/// and remains acknowledged even if its tasks are later removed or its account is disconnected.
public func prepareWelcome(_ store: Store, connected: Bool) throws -> Bool {
    try store.transaction {
        if try store.meta(welcomeCompletedKey).bool == true { return false }
        let hasData = try store.hasFields()
        if connected || hasData {
            try store.setMeta(welcomeCompletedKey, true)
            return false
        }
        return true
    }
}

public func completeWelcome(_ store: Store) throws {
    try store.transaction { try store.setMeta(welcomeCompletedKey, true) }
}
