import Foundation

/// What sync needs from the server. Api is the real one; tests use a fake.
public protocol SyncServer {
    func me() async throws -> JSON
    func sync(_ body: JSON) async throws -> JSON
}

public enum ApiError: Error, CustomStringConvertible {
    /// The server could not be reached, or did not answer in time.
    case offline(String)
    /// The server answered with an error.
    case server(status: Int, code: String, message: String)

    public var description: String {
        switch self {
        case .offline(let message): "offline: \(message)"
        case .server(let status, let code, let message): "\(status) \(code): \(message)"
        }
    }
}

/// HTTP client for the OpenTodo API. Foundation only.
public struct Api: SyncServer, Sendable {
    static let timeout: TimeInterval = 30

    public let baseURL: URL
    let token: String
    let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        baseURL = config.url
        token = config.token
        self.session = session
    }

    public func me() async throws -> JSON { try await send("GET", "/api/v1/me") }
    public func sync(_ body: JSON) async throws -> JSON { try await send("POST", "/api/v1/sync", body: body) }

    func send(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body.data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw ApiError.offline(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSON(parsing: data))?["error"] ?? .null
            throw ApiError.server(status: status, code: detail["code"].string ?? "http_error",
                                  message: detail["message"].string ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
        do {
            return try JSON(parsing: data)
        } catch {
            throw ApiError.server(status: status, code: "bad_response", message: "the server's answer isn't JSON")
        }
    }
}
