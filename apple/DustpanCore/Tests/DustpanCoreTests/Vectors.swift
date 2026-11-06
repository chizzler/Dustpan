import Foundation
@testable import DustpanCore

/// OpenTodo's shared test vectors, read from the pinned clone beside this repo. See spec/README.md.
enum Vectors {
    static let lib: URL = {
        if let src = ProcessInfo.processInfo.environment["OPENTODO_SRC"] {
            return URL(filePath: src).appending(path: "web/src/lib")
        }
        var url = URL(filePath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url.appending(path: "opentodo/web/src/lib")
    }()

    static func url(_ name: String) -> URL { lib.appending(path: "\(name).vectors.json") }

    static func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: url(name).path) }

    static func load(_ name: String) throws -> JSON { try JSON(parsing: Data(contentsOf: url(name))) }
}
