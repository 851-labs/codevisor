import ACPKit
import CodevisorProtocol
import Foundation

public enum CodevisorServerClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidDate(String)
    case invalidUUID(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "The server address “\(url)” isn't valid."
        case .invalidResponse:
            "The Codevisor server sent an unexpected response. Try again in a moment."
        case let .httpStatus(_, body):
            body.isEmpty ? "The Codevisor server rejected the request." : body
        case .invalidDate, .invalidUUID:
            "The Codevisor server sent data this version of Codevisor couldn't read. Updating Codevisor may fix this."
        }
    }
}

/// The machine-readable failure category from a server error body
/// (`{"error": …, "code": …}`), when the server classified the failure —
/// clone errors use this to pick actionable guidance.
public func serverErrorCode(_ error: any Error) -> String? {
    guard case let CodevisorServerClientError.httpStatus(_, body) = error,
        let data = body.data(using: .utf8),
        let payload = try? JSONDecoder().decode([String: String?].self, from: data)
    else { return nil }
    return payload["code"] ?? nil
}

/// The one message used for connection-level failures. Views compare an
/// error string against this to pair the message with a "Restart" recovery
/// action (HIG: offer the way out right where the error appears).
public let serverUnreachableErrorMessage = "Can't connect to the Codevisor server."

/// True when an error only says "the surrounding task was cancelled" —
/// Swift task cancellation or the URLSession request it tore down. These are
/// lifecycle noise (a pane was re-hosted, a view disappeared mid-load), not
/// failures: callers should return silently instead of surfacing them, since
/// whatever remounts the view reloads from scratch anyway. Without this
/// filter, every workspace-layout churn painted "cancelled" error rows into
/// otherwise healthy chats.
public func isTaskCancellation(_ error: any Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// A human-readable message for errors surfaced in the UI (HIG: say what
/// happened and what to do next, in plain language — never a raw NSError
/// dump). HTTP failures carry a JSON `{"error": "..."}` body from the
/// server — show that sentence, not the wrapped enum description.
public func serverErrorMessage(_ error: any Error) -> String {
    if case let CodevisorServerClientError.httpStatus(_, body) = error {
        if let data = body.data(using: .utf8),
            let payload = try? JSONDecoder().decode([String: String].self, from: data),
            let message = payload["error"]
        {
            return message
        }
        return body.isEmpty ? "The Codevisor server rejected the request." : body
    }
    // Connection-level failures: the URL, task ids, and CFNetwork internals
    // mean nothing to the user — reduce to the situation and the way out.
    if let urlError = error as? URLError {
        switch urlError.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
            .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork:
            return serverUnreachableErrorMessage
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            return "You appear to be offline. Check your network connection, then try again."
        default:
            return urlError.localizedDescription
        }
    }
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    // Cocoa/POSIX errors carry a system-provided sentence; anything else
    // falls back to its description rather than showing nothing.
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain || nsError.domain == NSURLErrorDomain
        || nsError.domain == NSPOSIXErrorDomain
    {
        return nsError.localizedDescription
    }
    return String(describing: error)
}

// MARK: - Transport seams

/// How a server client dispatches one HTTP request. The default is a plain
/// URLSession; cloud machines swap in a relay-backed transport that tunnels
/// the same requests through an end-to-end encrypted channel.
public protocol ServerRequestTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession-backed default request transport.
public struct URLSessionRequestTransport: ServerRequestTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodevisorServerClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}

/// A WebSocket message independent of URLSessionWebSocketTask, so relay-backed
/// and fake connections don't need Foundation's task types.
public enum ServerWebSocketMessage: Sendable, Equatable {
    case data(Data)
    case string(String)
}

/// One live WebSocket connection (already resumed). `receive` throws when the
/// connection dies — callers treat that as a disconnect and reconnect.
public protocol ServerWebSocketConnecting: AnyObject, Sendable {
    func send(_ message: ServerWebSocketMessage) async throws
    func receive() async throws -> ServerWebSocketMessage
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    /// The server-sent close code once the connection has closed, `.invalid`
    /// while it hasn't.
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
}

/// How a server client opens WebSocket connections — the socket sibling of
/// `ServerRequestTransport`.
public protocol ServerWebSocketTransport: Sendable {
    func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting
}

/// URLSessionWebSocketTask-backed default WebSocket transport.
public struct URLSessionWebSocketTransport: ServerWebSocketTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(_ request: URLRequest, maximumMessageSize: Int) -> any ServerWebSocketConnecting {
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

/// Thin adapter putting a URLSessionWebSocketTask behind the seam.
public final class URLSessionWebSocketConnection: ServerWebSocketConnecting, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(_ message: ServerWebSocketMessage) async throws {
        switch message {
        case let .data(data):
            try await task.send(.data(data))
        case let .string(text):
            try await task.send(.string(text))
        }
    }

    public func receive() async throws -> ServerWebSocketMessage {
        switch try await task.receive() {
        case let .data(data):
            return .data(data)
        case let .string(text):
            return .string(text)
        @unknown default:
            throw CodevisorServerClientError.invalidResponse
        }
    }

    public func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    public var closeCode: URLSessionWebSocketTask.CloseCode {
        task.closeCode
    }
}

public struct CodevisorServerConfig: Equatable, Sendable {
    public static let productionPort = CodevisorAppVariant.productionPort
    public static let developmentPort = CodevisorAppVariant.developmentPort

    public static var localPort: Int {
        CodevisorAppVariant.localServerPort
    }

    public var baseURL: URL
    public var bearerToken: String?
    /// Optional transport overrides. Nil keeps the URLSession defaults; cloud
    /// machines carry relay-backed transports here so every consumer of a
    /// config (server client, terminal transport) tunnels automatically.
    /// Excluded from Equatable: transports are plumbing, not identity.
    public var requestTransport: (any ServerRequestTransport)?
    public var webSocketTransport: (any ServerWebSocketTransport)?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(CodevisorServerConfig.localPort)")!,
        bearerToken: String? = nil,
        requestTransport: (any ServerRequestTransport)? = nil,
        webSocketTransport: (any ServerWebSocketTransport)? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.requestTransport = requestTransport
        self.webSocketTransport = webSocketTransport
    }

    public static func == (lhs: CodevisorServerConfig, rhs: CodevisorServerConfig) -> Bool {
        lhs.baseURL == rhs.baseURL && lhs.bearerToken == rhs.bearerToken
    }

    public static let localDefault = CodevisorServerConfig()
}

public final class CodevisorServerClient: CodevisorServerClienting, @unchecked Sendable {
    /// Foundation defaults WebSocket messages to 1 MiB. Tool results can
    /// legitimately exceed that (for example a broad repository search), so
    /// leave bounded headroom without altering the event payload.
    static let eventWebSocketMaximumMessageSize = 16 * 1024 * 1024
    let config: CodevisorServerConfig
    let requestTransport: any ServerRequestTransport
    let webSocketTransport: any ServerWebSocketTransport
    let requestGate: ServerRequestGate?
    let machineId: String?
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()

    public init(
        config: CodevisorServerConfig = .localDefault,
        urlSession: URLSession = .shared,
        requestGate: ServerRequestGate? = nil,
        machineId: String? = nil
    ) {
        self.config = config
        self.requestTransport =
            config.requestTransport
            ?? URLSessionRequestTransport(session: urlSession)
        self.webSocketTransport =
            config.webSocketTransport
            ?? URLSessionWebSocketTransport(session: urlSession)
        self.requestGate = requestGate
        self.machineId = machineId
    }

    func harnessAccountsPath(_ harnessId: String) -> String {
        "/v1/harnesses/\(pathComponent(harnessId))/accounts"
    }

    func harnessAccountPath(_ harnessId: String, _ accountId: String) -> String {
        "\(harnessAccountsPath(harnessId))/\(pathComponent(accountId))"
    }

    func openCodeProvidersPath(_ accountId: String) -> String {
        "/v1/harnesses/opencode/accounts/\(pathComponent(accountId))/providers"
    }

    func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: "GET", body: Optional<EmptyBody>.none)
    }

    func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try await perform(path, method: method, body: body, timeout: timeout)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    func sendNoResponse(_ path: String, method: String) async throws {
        try await sendNoResponse(path, method: method, body: Optional<EmptyBody>.none)
    }

    func sendNoResponse<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws {
        _ = try await perform(path, method: method, body: body)
    }

    @discardableResult
    func perform<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try await waitForServerIfNeeded(path: path)
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        if let timeout {
            request.timeoutInterval = timeout
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, httpResponse) = try await requestTransport.data(for: request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CodevisorServerClientError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    /// Sibling of `perform` for raw (non-JSON) bodies and responses — file
    /// uploads and downloads.
    func performRaw(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        let (data, _) = try await performRawResponse(
            path,
            method: method,
            body: body,
            contentType: contentType
        )
        return data
    }

    func performRawResponse(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> (Data, HTTPURLResponse) {
        try await waitForServerIfNeeded(path: path)
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, httpResponse) = try await requestTransport.data(for: request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw CodevisorServerClientError.httpStatus(httpResponse.statusCode, message)
        }
        return (data, httpResponse)
    }

    /// Lifecycle requests are what establish/re-establish readiness and must
    /// never wait on the gate they drive. Every other HTTP and WebSocket
    /// request waits before dispatch while startup/update downtime is known.
    func waitForServerIfNeeded(path: String) async throws {
        guard !Self.isLifecyclePath(path), let requestGate, let machineId else { return }
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG request.gate.begin machine=\(machineId, privacy: .public) path=\(path, privacy: .public)"
            )
        #endif
        try await requestGate.waitUntilReady(for: machineId)
        #if DEBUG || NAVIGATION_DIAGNOSTICS
            Log.cloud.notice(
                "CLOUDRELAYDBG request.gate.end machine=\(machineId, privacy: .public) path=\(path, privacy: .public)"
            )
        #endif
    }

    private static func isLifecyclePath(_ path: String) -> Bool {
        path == "/v1/health"
            || path == "/v1/info"
            || path == "/v1/shutdown"
            || path.hasPrefix("/v1/update")
    }

    func applyAuthorization(to request: inout URLRequest) {
        guard let bearerToken = config.bearerToken else { return }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    func url(for path: String) throws -> URL {
        let trimmedBase = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)\(path)") else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        return url
    }

    func websocketURL(for path: String) throws -> URL {
        let baseURL = try url(for: path)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        switch components.scheme {
        case "http":
            components.scheme = "ws"
        case "https":
            components.scheme = "wss"
        default:
            break
        }
        guard let url = components.url else {
            throw CodevisorServerClientError.invalidURL(path)
        }
        return url
    }
}

struct EmptyBody: Encodable {}
