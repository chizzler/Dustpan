import Foundation

public func wallMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

/// Hybrid logical clock for stamping ops. State lives in the store's meta table. See spec/sync.md, "Clock".
public final class HybridClock {
    static let skewTolerance: Int64 = 2_000
    static let maxAhead: Int64 = 5 * 60_000
    /// A refused clock this close to the server keeps going (OpenTodo issue #651).
    static let restartAfterRefusal = maxAhead / 2

    let store: Store
    let now: () -> Int64

    public init(store: Store, now: @escaping () -> Int64 = wallMs) {
        self.store = store
        self.now = now
    }

    public func last() throws -> Int64 { try store.meta("clock_last").int ?? 0 }
    public func offset() throws -> Int64 { try store.meta("clock_offset").int ?? 0 }

    /// A timestamp for a new local op, strictly after every one seen.
    public func stamp() throws -> Int64 {
        let ts = max(now() + (try offset()), try last() + 1)
        try store.setMeta("clock_last", .int(ts))
        return ts
    }

    /// Move past a timestamp seen on an incoming op.
    public func receive(_ ts: Int64) throws {
        if ts > (try last()) { try store.setMeta("clock_last", .int(ts)) }
    }

    /// Correct for a wrong local clock after an exchange.
    public func followServer(_ serverTime: Int64) throws {
        let skew = serverTime - now()
        try store.setMeta("clock_offset", .int(abs(skew) > Self.skewTolerance ? skew : 0))
        if try last() > serverTime + Self.maxAhead { try store.setMeta("clock_last", .int(serverTime)) }
    }

    /// The server refused ops for clock skew: restart from its time if well ahead of it.
    ///
    /// A clock closer than that holds stamps an earlier refusal in this exchange just gave out.
    /// Going back below them would stamp a later edit before an earlier one.
    public func refused(_ serverTime: Int64) throws {
        try followServer(serverTime)
        if try last() > serverTime + Self.restartAfterRefusal { try store.setMeta("clock_last", .int(serverTime)) }
    }
}
