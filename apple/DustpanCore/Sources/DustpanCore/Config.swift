import Foundation

/// The server and token, read from a KEY=VALUE file: OPENTODO_URL and OPENTODO_TOKEN.
///
/// The file is ~/.config/dustpan/config, as on the desktop. DUSTPAN_CONFIG overrides it for development.
/// The URL must be https, except to this machine: the token travels in every request.
public struct Config: Sendable, Equatable {
    public let url: URL
    public let token: String

    public static func path(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["DUSTPAN_CONFIG"], !path.isEmpty { return URL(filePath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/dustpan/config")
    }

    public static func load(from path: URL = path()) throws(ConfigError) -> Config {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw ConfigError(message: "no config at \(path.path)")
        }
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "="), !line.drop(while: \.isWhitespace).hasPrefix("#") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] =
                line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        guard let urlText = values["OPENTODO_URL"], !urlText.isEmpty,
              let token = values["OPENTODO_TOKEN"], !token.isEmpty
        else { throw ConfigError(message: "\(path.path) needs OPENTODO_URL and OPENTODO_TOKEN") }
        guard let url = URL(string: urlText), isSafe(url) else {
            throw ConfigError(message: "\(path.path): OPENTODO_URL must start with https:// (http only for localhost)")
        }
        return Config(url: url, token: token)
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
