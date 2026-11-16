import Foundation

// The live update stream: the server says when there's something to pull.
// See spec/writes.md, "Live updates". Events carry only a cursor, never data.

/// Reads a server-sent event stream line by line and hands back the data of each "ops" event.
struct EventParser {
    private var event: String?
    private var data: [String] = []
    private var line: [UInt8] = []

    /// One byte of the stream. Lines end in LF, with an optional CR before it.
    mutating func feed(byte: UInt8) -> JSON? {
        guard byte == UInt8(ascii: "\n") else {
            line.append(byte)
            return nil
        }
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        defer { line.removeAll(keepingCapacity: true) }
        return feed(String(decoding: line, as: UTF8.self))
    }

    /// One line, without its line ending. Returns an ops event's data when a blank line ends one.
    mutating func feed(_ line: String) -> JSON? {
        guard !line.isEmpty else {
            defer { (event, data) = (nil, []) }
            guard event == "ops" else { return nil }
            let value = try? JSON(parsing: data.isEmpty ? "{}" : data.joined(separator: "\n"))
            return value?.object != nil ? value : [:]
        }
        if line.hasPrefix(":") { return nil }
        let (name, value) = line.firstIndex(of: ":").map { colon in
            (line[..<colon], line[line.index(after: colon)...].trimmingPrefix(" "))
        } ?? (line[...], "")
        switch name {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}

public enum LiveEvent: Equatable, Sendable {
    /// The stream is open: sync once.
    case connected
    /// Something changed on the server. Sync when cursor is newer than ours, or nil.
    case ops(cursor: Int64?)
    case disconnected
}

extension Api {
    static let streamTimeout: TimeInterval = 60  // the server pings every 25 s

    /// Keep one event stream open, reconnecting after 1 s, doubling to 30 s, with jitter. Ends when cancelled.
    public func liveEvents(device: String) -> AsyncStream<LiveEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                var delay = 1.0
                while !Task.isCancelled {
                    do {
                        let bytes = try await openEvents(device: device)
                        try Task.checkCancellation()
                        continuation.yield(.connected)
                        delay = 1
                        var parser = EventParser()
                        for try await byte in bytes {
                            try Task.checkCancellation()
                            if let data = parser.feed(byte: byte) { continuation.yield(.ops(cursor: data["cursor"].int)) }
                        }
                    } catch {}
                    guard !Task.isCancelled else { break }
                    continuation.yield(.disconnected)
                    do { try await Task.sleep(for: .seconds(delay * .random(in: 0.5...1))) } catch { break }
                    delay = min(delay * 2, 30)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func openEvents(device: String) async throws -> URLSession.AsyncBytes {
        var components = URLComponents(url: baseURL.appending(path: "/api/v1/sync/events"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "device", value: device)]
        var request = URLRequest(url: components.url!, timeoutInterval: Self.streamTimeout)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirect.shared)
        try refuseRedirect(response)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ApiError.server(status: status, code: "http_error",
                                  message: HTTPURLResponse.localizedString(forStatusCode: status))
        }
        return bytes
    }
}
