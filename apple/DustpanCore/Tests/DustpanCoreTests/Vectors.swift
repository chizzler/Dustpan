import Foundation
@testable import DustpanCore

/// OpenTodo's shared test vectors, read from the pinned clone beside this repo. See spec/README.md.
enum Vectors {
    /// The clone's root.
    static let root: URL = {
        if let src = ProcessInfo.processInfo.environment["OPENTODO_SRC"] { return URL(filePath: src) }
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appending(path: "opentodo")
    }()

    static let lib = root.appending(path: "web/src/lib")

    static func fileExists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relative).path)
    }

    /// A file's text from the clone.
    static func read(_ relative: String) throws -> String {
        try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }

    static func url(_ name: String) -> URL { lib.appending(path: "\(name).vectors.json") }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    static func load(_ name: String) throws -> JSON { try JSON(parsing: Data(contentsOf: url(name))) }
}
