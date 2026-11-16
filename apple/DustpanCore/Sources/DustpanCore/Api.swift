import Foundation

/// What sync needs from the server. Api is the real one; tests use a fake.
public protocol SyncServer {
    func me() async throws -> JSON
    func sync(_ body: JSON) async throws -> JSON
    /// Delete a task or project in the Trash for good. 409 not_deleted if it isn't there.
    func purge(entity: String, id: String) async throws
    /// Which account the connection is: its server and a digest of its token. Nil when it can't say.
    var accountKey: JSON? { get }
}

public extension SyncServer {
    var accountKey: JSON? { nil }
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

/// Refuses redirects, as the desktop does. URLSession drops the token on a redirect to another origin, then fails
/// with a puzzling answer from wherever it landed. The API never redirects, so the 3xx itself comes back and
/// `refuseRedirect` turns it into an error that says what to fix.
final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = NoRedirect()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func refuseRedirect(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (300..<400).contains(http.statusCode) else { return }
    let target = http.value(forHTTPHeaderField: "Location") ?? "another address"
    throw ApiError.server(status: http.statusCode, code: "redirect",
                          message: "server redirected to \(target); update OPENTODO_URL")
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

    public var accountKey: JSON? { DustpanCore.accountKey(url: baseURL, token: token) }

    public func me() async throws -> JSON { try await send("GET", ["api", "v1", "me"]) }
    public func sync(_ body: JSON) async throws -> JSON { try await send("POST", ["api", "v1", "sync"], body: body) }

    public func purge(entity: String, id: String) async throws {
        _ = try await send("DELETE", ["api", "v1", entity + "s", id, "purge"])
    }

    /// Each path component is percent-encoded, a slash in an id too.
    func send(_ method: String, _ path: [String], body: JSON? = nil) async throws -> JSON {
        var request = URLRequest(url: path.reduce(baseURL) { $0.appending(component: $1) }, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body.data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect.shared)
        } catch let error as URLError {
            if error.code == .cancelled && Task.isCancelled { throw CancellationError() }
            throw ApiError.offline(error.localizedDescription)
        }
        try refuseRedirect(response)
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
