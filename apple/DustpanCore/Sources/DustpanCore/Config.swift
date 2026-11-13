import Foundation

/// The server and token, read from a KEY=VALUE file: OPENTODO_URL and OPENTODO_TOKEN.
///
/// The file is ~/.config/dustpan/config, as on the desktop. DUSTPAN_CONFIG overrides it for development.
/// Without one, Dustpan runs standalone. The URL must be https, except to this machine: the token travels in every
/// request.
public struct Config: Sendable, Equatable {
    static let keys: Set = ["OPENTODO_URL", "OPENTODO_TOKEN"]

    public let url: URL
    public let token: String

    public init(url: URL, token: String) {
        (self.url, self.token) = (url, token)
    }

    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["DUSTPAN_CONFIG"], !path.isEmpty { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/dustpan/config")
    }

    public static func load(from path: URL = path()) throws(ConfigError) -> Config {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw ConfigError(message: "no config at \(path.path)")
        }
        let values = parse(text)
        return try validate(url: values["OPENTODO_URL"] ?? "", token: values["OPENTODO_TOKEN"] ?? "", source: path.path)
    }

    /// The config, or nil to run standalone: no file, or blank values. A file that's wrong also runs standalone,
    /// with a warning saying why, so its tasks stay reachable.
    public static func loadOptional(from path: URL = path()) -> (config: Config?, warning: String?) {
        guard FileManager.default.fileExists(atPath: path.path) else { return (nil, nil) }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return (nil, "Could not read \(path.path)")
        }
        let values = parse(text)
        let url = values["OPENTODO_URL"] ?? "", token = values["OPENTODO_TOKEN"] ?? ""
        if url.isEmpty && token.isEmpty { return (nil, nil) }
        do {
            return (try validate(url: url, token: token, source: path.path), nil)
        } catch {
            return (nil, error.message)
        }
    }

    /// A server URL and token as typed or read, checked.
    public static func validate(url: String, token: String, source: String? = nil) throws(ConfigError) -> Config {
        let prefix = source.map { "\($0): " } ?? ""
        let url = url.trimmingCharacters(in: .whitespaces), token = token.trimmingCharacters(in: .whitespaces)
        if (url + token).contains(where: \.isNewline) {
            throw ConfigError(message: prefix + "URL and token must be single-line values")
        }
        guard !url.isEmpty, !token.isEmpty else {
            throw ConfigError(message: source.map { "\($0) needs OPENTODO_URL and OPENTODO_TOKEN" }
                ?? "Enter both the server URL and API token")
        }
        guard let parsed = URL(string: url), isSafe(parsed) else {
            throw ConfigError(message: prefix + "OPENTODO_URL must start with https:// (http only for localhost)")
        }
        return Config(url: parsed, token: token)
    }

    /// Write OPENTODO_URL and OPENTODO_TOKEN with mode 600, keeping the file's other lines.
    public func save(to path: URL = Config.path()) throws {
        let lines = Self.otherLines(path) + ["OPENTODO_URL=\(url.absoluteString)", "OPENTODO_TOKEN=\(token)"]
        try Self.writePrivate(path, lines.joined(separator: "\n") + "\n")
    }

    /// Take the server and token out of the file, to run standalone. A file left with nothing in it goes.
    public static func clear(at path: URL = path()) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let kept = otherLines(path)
        if kept.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            try writePrivate(path, kept.joined(separator: "\n") + "\n")
        } else {
            try FileManager.default.removeItem(at: path)
        }
    }

    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = setting(line) else { continue }
            values[key] = value
        }
        return values
    }

    private static func setting(_ line: Substring) -> (String, String)? {
        guard let eq = line.firstIndex(of: "="), !line.drop(while: \.isWhitespace).hasPrefix("#") else { return nil }
        return (line[..<eq].trimmingCharacters(in: .whitespaces),
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
    }

    private static func otherLines(_ path: URL) -> [String] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0)
            .filter { line in setting(line).map { !keys.contains($0.0) } ?? true }.map(String.init)
    }

    /// Written beside the file and moved over it, so a reader never sees half of it or another mode.
    private static func writePrivate(_ path: URL, _ text: String) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".config-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: Data(text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ConfigError(message: "can't write \(path.path)")
        }
        guard rename(temporary.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw ConfigError(message: "can't write \(path.path)")
        }
    }

    /// True for https, or plain http to this machine.
    public static func isSafe(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        switch url.scheme {
        case "https": return true
        case "http": return host == "localhost" || isLoopback(host)
        default: return false
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// Where the local copy lives: ~/Library/Application Support/Dustpan. DUSTPAN_DATA overrides it.
public func databasePath(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    let directory: URL
    if let path = environment["DUSTPAN_DATA"], !path.isEmpty {
        directory = URL(filePath: path)
    } else {
        directory = URL.applicationSupportDirectory.appending(path: "Dustpan")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "dustpan.db").path
}
