import Foundation
import ACPKit

public enum HerdManServerClientError: Error, Equatable, Sendable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidDate(String)
    case invalidUUID(String)
}

public protocol HerdManServerClienting: Sendable {
    func health() async throws -> ServerHealth
    func listHarnesses() async throws -> [ServerHarness]
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness
    func listWorkspaces() async throws -> [ServerWorkspace]
    func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace
    func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace
    func deleteWorkspace(id: UUID) async throws
    func listSessions() async throws -> [ServerSession]
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail
    func upsertSession(_ session: ChatSession) async throws -> ServerSession
    func updateSession(_ session: ChatSession) async throws -> ServerSession
    func deleteSession(id: UUID) async throws
    func promptSession(id: UUID, text: String) async throws -> StopReason
    func cancelSession(id: UUID) async throws
    func setSessionMode(id: UUID, modeId: String) async throws
    func setSessionConfig(id: UUID, configId: String, value: String) async throws
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
}

public struct HerdManServerConfig: Equatable, Sendable {
    public var baseURL: URL
    public var bearerToken: String?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:8765")!,
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
    }

    public static let localDefault = HerdManServerConfig()
}

public struct ServerHealth: Decodable, Equatable, Sendable {
    public var ok: Bool
    public var version: String
    public var database: String
}

public struct ServerHarnessReadiness: Decodable, Equatable, Sendable {
    public var state: String
    public var detail: String?
}

public struct ServerHarness: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var source: String
    public var launchKind: String
    public var enabled: Bool
    public var readiness: ServerHarnessReadiness
}

public struct ServerWorkspace: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var folderPath: String
    public var isArchived: Bool
    public var symbolName: String
    public var origin: SessionOrigin
    public var createdAt: String

    public func workspace() throws -> Workspace {
        guard let uuid = UUID(uuidString: id) else {
            throw HerdManServerClientError.invalidUUID(id)
        }
        return Workspace(
            id: uuid,
            name: name,
            folderURL: URL(fileURLWithPath: folderPath),
            isArchived: isArchived,
            symbolName: symbolName,
            origin: origin,
            createdAt: try ServerDateCoding.date(from: createdAt)
        )
    }
}

public struct ServerSessionUsage: Decodable, Equatable, Sendable {
    public var used: Double?
    public var size: Double?
    public var costAmount: Double?
    public var costCurrency: String?
}

public struct ServerSession: Decodable, Equatable, Sendable {
    public var id: String
    public var workspaceId: String
    public var serverId: String
    public var harnessId: String
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    public var createdAt: String
    public var updatedAt: String?
    public var usage: ServerSessionUsage?

    public func chatSession() throws -> ChatSession {
        guard let uuid = UUID(uuidString: id) else {
            throw HerdManServerClientError.invalidUUID(id)
        }
        guard let workspaceUUID = UUID(uuidString: workspaceId) else {
            throw HerdManServerClientError.invalidUUID(workspaceId)
        }
        return ChatSession(
            id: uuid,
            workspaceId: workspaceUUID,
            serverId: serverId,
            harnessId: harnessId,
            agentSessionId: agentSessionId,
            title: title,
            origin: origin,
            isArchived: isArchived,
            createdAt: try ServerDateCoding.date(from: createdAt),
            updatedAt: try updatedAt.map(ServerDateCoding.date)
        )
    }
}

public enum ServerConversationRole: String, Decodable, Equatable, Sendable {
    case user
    case assistant
    case system
}

public struct ServerConversationItem: Decodable, Equatable, Sendable {
    public var id: String
    public var role: ServerConversationRole
    public var text: String
    public var createdAt: String
    public var isGenerating: Bool
}

public struct ServerSessionDetail: Decodable, Equatable, Sendable {
    public var session: ServerSession
    public var conversation: [ServerConversationItem]
    public var eventCursor: Int
}

public struct ServerEventEnvelope: Decodable, Equatable, Sendable {
    public var id: Int
    public var serverId: String
    public var kind: String
    public var subjectId: String
    public var createdAt: String
    public var payload: JSONValue
}

public final class HerdManServerClient: HerdManServerClienting, @unchecked Sendable {
    private let config: HerdManServerConfig
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(
        config: HerdManServerConfig = .localDefault,
        urlSession: URLSession = .shared
    ) {
        self.config = config
        self.urlSession = urlSession
    }

    public func health() async throws -> ServerHealth {
        try await get("/v1/health")
    }

    public func listHarnesses() async throws -> [ServerHarness] {
        try await get("/v1/harnesses")
    }

    public func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        try await send(
            "/v1/harnesses/\(id)",
            method: "PATCH",
            body: UpdateHarnessBody(enabled: enabled)
        )
    }

    public func listWorkspaces() async throws -> [ServerWorkspace] {
        try await get("/v1/workspaces")
    }

    public func upsertWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace {
        let remoteWorkspaces = try await listWorkspaces()
        if remoteWorkspaces.contains(where: { $0.id == workspace.id.uuidString }) {
            return try await updateWorkspace(workspace)
        }
        return try await createWorkspace(workspace)
    }

    public func updateWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace {
        try await send(
            "/v1/workspaces/\(workspace.id.uuidString)",
            method: "PATCH",
            body: UpdateWorkspaceBody(workspace: workspace)
        )
    }

    public func deleteWorkspace(id: UUID) async throws {
        try await sendNoResponse("/v1/workspaces/\(id.uuidString)", method: "DELETE")
    }

    public func listSessions() async throws -> [ServerSession] {
        try await get("/v1/sessions")
    }

    public func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        try await get("/v1/sessions/\(id.uuidString)")
    }

    public func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        let remoteSessions = try await listSessions()
        if remoteSessions.contains(where: { $0.id == session.id.uuidString }) {
            return try await updateSession(session)
        }
        return try await createSession(session)
    }

    public func updateSession(_ session: ChatSession) async throws -> ServerSession {
        try await send(
            "/v1/sessions/\(session.id.uuidString)",
            method: "PATCH",
            body: UpdateSessionBody(session: session)
        )
    }

    public func deleteSession(id: UUID) async throws {
        try await sendNoResponse("/v1/sessions/\(id.uuidString)", method: "DELETE")
    }

    public func promptSession(id: UUID, text: String) async throws -> StopReason {
        let response: PromptActionResponse = try await send(
            "/v1/sessions/\(id.uuidString)/prompt",
            method: "POST",
            body: PromptBody(text: text)
        )
        return response.stopReason
    }

    public func cancelSession(id: UUID) async throws {
        try await sendNoResponse("/v1/sessions/\(id.uuidString)/cancel", method: "POST")
    }

    public func setSessionMode(id: UUID, modeId: String) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/mode",
            method: "POST",
            body: SetModeBody(modeId: modeId)
        )
    }

    public func setSessionConfig(id: UUID, configId: String, value: String) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/config",
            method: "POST",
            body: SetConfigBody(configId: configId, value: value)
        )
    }

    public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: try url(for: "/v1/events?since=\(since)"))
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    applyAuthorization(to: &request)

                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw HerdManServerClientError.invalidResponse
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        throw HerdManServerClientError.httpStatus(httpResponse.statusCode, "")
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let raw = line.dropFirst("data: ".count)
                        guard let data = raw.data(using: .utf8) else { continue }
                        continuation.yield(try decoder.decode(ServerEventEnvelope.self, from: data))
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func createWorkspace(_ workspace: Workspace) async throws -> ServerWorkspace {
        try await send(
            "/v1/workspaces",
            method: "POST",
            body: CreateWorkspaceBody(workspace: workspace)
        )
    }

    private func createSession(_ session: ChatSession) async throws -> ServerSession {
        try await send(
            "/v1/sessions",
            method: "POST",
            body: CreateSessionBody(session: session)
        )
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        try await send(path, method: "GET", body: Optional<EmptyBody>.none)
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        let data = try await perform(path, method: method, body: body)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw error
        }
    }

    private func sendNoResponse(_ path: String, method: String) async throws {
        try await sendNoResponse(path, method: method, body: Optional<EmptyBody>.none)
    }

    private func sendNoResponse<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws {
        _ = try await perform(path, method: method, body: body)
    }

    @discardableResult
    private func perform<Body: Encodable>(
        _ path: String,
        method: String,
        body: Body?
    ) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HerdManServerClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw HerdManServerClientError.httpStatus(httpResponse.statusCode, message)
        }
        return data
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let bearerToken = config.bearerToken else { return }
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }

    private func url(for path: String) throws -> URL {
        let trimmedBase = config.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmedBase)\(path)") else {
            throw HerdManServerClientError.invalidURL(path)
        }
        return url
    }
}

private enum ServerDateCoding {
    static func string(from date: Date) -> String {
        formatter(includeFractionalSeconds: true).string(from: date)
    }

    static func date(from string: String) throws -> Date {
        if let date = formatter(includeFractionalSeconds: true).date(from: string) {
            return date
        }
        if let date = formatter(includeFractionalSeconds: false).date(from: string) {
            return date
        }
        throw HerdManServerClientError.invalidDate(string)
    }

    private static func formatter(includeFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = includeFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}

private struct EmptyBody: Encodable {}

private struct PromptActionResponse: Decodable {
    var stopReason: StopReason
}

private struct PromptBody: Encodable {
    var text: String
}

private struct SetModeBody: Encodable {
    var modeId: String
}

private struct SetConfigBody: Encodable {
    var configId: String
    var value: String
}

private struct UpdateHarnessBody: Encodable {
    var enabled: Bool
}

private struct CreateWorkspaceBody: Encodable {
    var id: String
    var folderPath: String
    var name: String
    var isArchived: Bool
    var symbolName: String
    var origin: SessionOrigin
    var createdAt: String

    init(workspace: Workspace) {
        id = workspace.id.uuidString
        folderPath = workspace.folderURL.path
        name = workspace.name
        isArchived = workspace.isArchived
        symbolName = workspace.symbolName
        origin = workspace.origin
        createdAt = ServerDateCoding.string(from: workspace.createdAt)
    }
}

private struct UpdateWorkspaceBody: Encodable {
    var name: String
    var isArchived: Bool
    var symbolName: String

    init(workspace: Workspace) {
        name = workspace.name
        isArchived = workspace.isArchived
        symbolName = workspace.symbolName
    }
}

private struct CreateSessionBody: Encodable {
    var id: String
    var workspaceId: String
    var harnessId: String
    var agentSessionId: String?
    var title: String
    var origin: SessionOrigin
    var isArchived: Bool
    var createdAt: String
    var updatedAt: String?

    init(session: ChatSession) {
        id = session.id.uuidString
        workspaceId = session.workspaceId.uuidString
        harnessId = session.harnessId
        agentSessionId = session.agentSessionId
        title = session.title
        origin = session.origin
        isArchived = session.isArchived
        createdAt = ServerDateCoding.string(from: session.createdAt)
        updatedAt = session.updatedAt.map(ServerDateCoding.string)
    }
}

private struct UpdateSessionBody: Encodable {
    var agentSessionId: String?
    var isArchived: Bool
    var title: String

    init(session: ChatSession) {
        agentSessionId = session.agentSessionId
        isArchived = session.isArchived
        title = session.title
    }
}
