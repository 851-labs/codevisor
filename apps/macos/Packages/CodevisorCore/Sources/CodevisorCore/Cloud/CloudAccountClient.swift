import Foundation

/// The discovery document a Codevisor Cloud instance serves at
/// `/.well-known/codevisor` — validated before a custom server is trusted.
public struct CloudInstanceInfo: Codable, Equatable, Sendable {
    public var service: String
    public var instance: String?
    public var version: String?
    public var protocols: [Int]?
    public var authProviders: [String]?

    public init(
        service: String,
        instance: String? = nil,
        version: String? = nil,
        protocols: [Int]? = nil,
        authProviders: [String]? = nil
    ) {
        self.service = service
        self.instance = instance
        self.version = version
        self.protocols = protocols
        self.authProviders = authProviders
    }

    /// The service identifier a real Codevisor Cloud instance reports.
    public static let expectedService = "codevisor-cloud"
}

/// A machine connected to the signed-in cloud account, as reported by
/// `GET /api/machines`.
public struct CloudMachine: Codable, Identifiable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var os: String?
    public var appVersion: String?
    public var publicKey: String
    public var online: Bool
    /// ISO timestamp of the last connect/disconnect the hub observed.
    public var lastSeenAt: String

    public var id: String { deviceId }

    public init(
        deviceId: String,
        name: String,
        os: String? = nil,
        appVersion: String? = nil,
        publicKey: String,
        online: Bool,
        lastSeenAt: String
    ) {
        self.deviceId = deviceId
        self.name = name
        self.os = os
        self.appVersion = appVersion
        self.publicKey = publicKey
        self.online = online
        self.lastSeenAt = lastSeenAt
    }
}

/// The signed-in user, parsed from `GET /api/auth/get-session`.
public struct CloudSessionUser: Equatable, Sendable {
    public var userId: String
    public var email: String?
    public var name: String?

    public init(userId: String, email: String? = nil, name: String? = nil) {
        self.userId = userId
        self.email = email
        self.name = name
    }
}

public enum CloudAccountClientError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int)
    case notACloudInstance
    case missingToken

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "The server address “\(url)” isn't valid."
        case .invalidResponse:
            "The server sent an unexpected response. Try again in a moment."
        case let .httpStatus(status):
            status == 401
                ? "Your sign-in has expired. Sign in again."
                : "The server rejected the request (HTTP \(status))."
        case .notACloudInstance:
            "That server doesn't look like a Codevisor Cloud instance. Check the URL and try again."
        case .missingToken:
            "Sign-in didn't complete: the server didn't return a session token."
        }
    }
}

/// The small REST surface the app needs from a Codevisor Cloud instance.
/// Abstracted so the account controller is testable with a fake.
public protocol CloudAccountClienting: Sendable {
    /// `GET /.well-known/codevisor` — the discovery/validation document.
    func discover() async throws -> CloudInstanceInfo
    /// Exchanges the browser handoff's one-time token for a session bearer
    /// token (`POST /api/auth/one-time-token/verify`).
    func verifyOneTimeToken(_ ott: String) async throws -> String
    /// `GET /api/auth/get-session` — nil when the token no longer maps to a
    /// live session.
    func session(token: String) async throws -> CloudSessionUser?
    func machines(token: String) async throws -> [CloudMachine]
    func rename(deviceId: String, name: String, token: String) async throws
    func removeMachine(deviceId: String, token: String) async throws
}

/// Minimal URLSession JSON client for one cloud instance.
public final class CloudAccountClient: CloudAccountClienting, Sendable {
    private let baseURL: URL
    private let urlSession: URLSession

    /// Cookie-free by default: this client authenticates with bearer tokens
    /// only. A shared URLSession would store the session cookie that
    /// endpoints like one-time-token/verify also set — and Better Auth
    /// rejects cookie-bearing POSTs without an Origin header (CSRF, 403), so
    /// a stored cookie breaks every later sign-in.
    public static func makeCookieFreeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    public init(baseURL: URL, urlSession: URLSession = CloudAccountClient.makeCookieFreeSession()) {
        self.baseURL = baseURL
        self.urlSession = urlSession
    }

    public func discover() async throws -> CloudInstanceInfo {
        let (data, _) = try await perform("/.well-known/codevisor")
        guard let info = try? JSONDecoder().decode(CloudInstanceInfo.self, from: data) else {
            // A reachable web server that isn't a cloud instance (a marketing
            // page, a proxy error) answers 200 with something else entirely.
            throw CloudAccountClientError.notACloudInstance
        }
        return info
    }

    public func verifyOneTimeToken(_ ott: String) async throws -> String {
        let body = try JSONEncoder().encode(["token": ott])
        let (data, response) = try await perform(
            "/api/auth/one-time-token/verify",
            method: "POST",
            body: body
        )
        // The bearer plugin returns the session token in a response header;
        // fall back to a `token` field in the body for older instances.
        if let header = response.value(forHTTPHeaderField: "set-auth-token"), !header.isEmpty {
            return header
        }
        struct VerifyBody: Decodable {
            var token: String?
        }
        if let token = (try? JSONDecoder().decode(VerifyBody.self, from: data))?.token,
           !token.isEmpty {
            return token
        }
        throw CloudAccountClientError.missingToken
    }

    public func session(token: String) async throws -> CloudSessionUser? {
        let (data, _) = try await perform("/api/auth/get-session", token: token)
        // No session is a 200 with a literal `null` body.
        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return nil }
        struct SessionBody: Decodable {
            struct User: Decodable {
                var id: String
                var email: String?
                var name: String?
            }

            var user: User
        }
        guard let session = try? JSONDecoder().decode(SessionBody.self, from: data) else {
            return nil
        }
        return CloudSessionUser(
            userId: session.user.id,
            email: session.user.email,
            name: session.user.name
        )
    }

    public func machines(token: String) async throws -> [CloudMachine] {
        struct MachinesBody: Decodable {
            var machines: [CloudMachine]
        }
        let (data, _) = try await perform("/api/machines", token: token)
        do {
            return try JSONDecoder().decode(MachinesBody.self, from: data).machines
        } catch {
            throw CloudAccountClientError.invalidResponse
        }
    }

    public func rename(deviceId: String, name: String, token: String) async throws {
        let body = try JSONEncoder().encode(["name": name])
        _ = try await perform(
            "/api/machines/\(escaped(deviceId))/rename",
            method: "POST",
            body: body,
            token: token
        )
    }

    public func removeMachine(deviceId: String, token: String) async throws {
        _ = try await perform(
            "/api/machines/\(escaped(deviceId))",
            method: "DELETE",
            token: token
        )
    }

    // MARK: - Request plumbing

    private func escaped(_ pathComponent: String) -> String {
        pathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? pathComponent
    }

    private func url(for path: String) throws -> URL {
        let trimmedBase = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard let url = URL(string: trimmedBase + path) else {
            throw CloudAccountClientError.invalidURL(trimmedBase + path)
        }
        return url
    }

    @discardableResult
    private func perform(
        _ path: String,
        method: String = "GET",
        body: Data? = nil,
        token: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudAccountClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CloudAccountClientError.httpStatus(httpResponse.statusCode)
        }
        return (data, httpResponse)
    }
}
