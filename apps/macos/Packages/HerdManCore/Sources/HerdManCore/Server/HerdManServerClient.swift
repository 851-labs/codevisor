import Foundation
import ACPKit

public enum HerdManServerClientError: Error, Equatable, Sendable {
    case invalidURL(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidDate(String)
    case invalidUUID(String)
}

/// A human-readable message for errors surfaced in the UI: HTTP failures
/// carry a JSON `{"error": "..."}` body from the server — show that sentence,
/// not the wrapped enum description.
public func serverErrorMessage(_ error: any Error) -> String {
    if case let HerdManServerClientError.httpStatus(_, body) = error {
        if let data = body.data(using: .utf8),
           let payload = try? JSONDecoder().decode([String: String].self, from: data),
           let message = payload["error"] {
            return message
        }
        return body.isEmpty ? "The HerdMan server rejected the request." : body
    }
    return String(describing: error)
}

public protocol HerdManServerClienting: Sendable {
    func health() async throws -> ServerHealth
    func info() async throws -> ServerInfo
    func updateInfo() async throws -> ServerUpdateInfo
    func issuePairingToken() async throws -> ServerPairingToken
    func capabilities(cwd: String) async throws -> ServerCapabilities
    func listHarnesses() async throws -> [ServerHarness]
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness
    func listProjects() async throws -> [ServerProject]
    func upsertProject(_ project: Project) async throws -> ServerProject
    func updateProject(_ project: Project) async throws -> ServerProject
    func deleteProject(id: UUID) async throws
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree]
    func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree
    func listSessions() async throws -> [ServerSession]
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail
    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem]
    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope]
    func upsertSession(_ session: ChatSession) async throws -> ServerSession
    func updateSession(_ session: ChatSession) async throws -> ServerSession
    func touchSession(id: UUID, updatedAt: Date) async throws
    func deleteSession(id: UUID) async throws
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted
    func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata
    func fileData(id: String) async throws -> Data
    func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem
    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws
    func cancelSession(id: UUID) async throws
    func setSessionMode(id: UUID, modeId: String) async throws
    func setSessionConfig(id: UUID, configId: String, value: String) async throws
    func requestShutdown() async throws
    func applyServerUpdate() async throws -> ServerUpdateApplied
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error>
}

public extension HerdManServerClienting {
    func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] { [] }

    /// Default for fakes/older transports: attachments are dropped and the
    /// text-only prompt path is used.
    func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text)
    }

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real file endpoints.
    func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        throw HerdManServerClientError.invalidResponse
    }

    func fileData(id: String) async throws -> Data {
        throw HerdManServerClientError.invalidResponse
    }

    /// Default for fakes/older servers: no persisted history, callers fall
    /// back to the text-only conversation snapshot.
    func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] { [] }

    /// Default no-op so fakes and older transports keep compiling; the HTTP
    /// client overrides this with `POST /v1/shutdown`.
    func requestShutdown() async throws {}

    /// Default for fakes/older transports: the server declined the update.
    func applyServerUpdate() async throws -> ServerUpdateApplied {
        ServerUpdateApplied(accepted: false, targetVersion: nil)
    }

    func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem {
        ServerPromptQueueItem(
            id: queueItemId,
            sessionId: sessionId.uuidString,
            text: text,
            createdAt: ServerDateCoding.string(from: Date()),
            updatedAt: ServerDateCoding.string(from: Date())
        )
    }

    func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {}

    /// Default no-op so fakes and older transports keep compiling; the HTTP
    /// client overrides this with a PATCH carrying the activity stamp.
    func touchSession(id: UUID, updatedAt: Date) async throws {}

    /// Defaults so fakes and older transports keep compiling; the HTTP client
    /// overrides these with the real worktree endpoints.
    func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] { [] }

    func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
        throw HerdManServerClientError.invalidResponse
    }
}

public struct HerdManServerConfig: Equatable, Sendable {
    public static let productionPort = HerdManAppVariant.productionPort
    public static let developmentPort = HerdManAppVariant.developmentPort

    public static var localPort: Int {
        HerdManAppVariant.localServerPort
    }

    public var baseURL: URL
    public var bearerToken: String?

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:\(HerdManServerConfig.localPort)")!,
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

public struct ServerInfo: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var version: String
    public var platform: String
    public var bindHost: String
}

public struct ServerUpdateInfo: Decodable, Equatable, Sendable {
    public var currentVersion: String
    public var latestVersion: String
    public var updateAvailable: Bool
    public var channel: String
    public var checkedAt: String?
    public var migrationState: String

    public init(
        currentVersion: String,
        latestVersion: String,
        updateAvailable: Bool,
        channel: String,
        checkedAt: String?,
        migrationState: String
    ) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.channel = channel
        self.checkedAt = checkedAt
        self.migrationState = migrationState
    }
}

/// Response of `POST /v1/update/apply`.
public struct ServerUpdateApplied: Decodable, Equatable, Sendable {
    public var accepted: Bool
    public var targetVersion: String?

    public init(accepted: Bool, targetVersion: String?) {
        self.accepted = accepted
        self.targetVersion = targetVersion
    }
}

public struct ServerPairingToken: Decodable, Equatable, Sendable {
    public var token: String
    public var createdAt: String
}

public struct ServerHarnessReadiness: Codable, Equatable, Sendable {
    public var state: String
    public var detail: String?

    public init(state: String, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }
}

public struct ServerHarness: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var symbolName: String
    public var source: String
    public var launchKind: String
    public var enabled: Bool
    public var readiness: ServerHarnessReadiness

    public init(
        id: String,
        name: String,
        symbolName: String,
        source: String,
        launchKind: String,
        enabled: Bool,
        readiness: ServerHarnessReadiness
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.source = source
        self.launchKind = launchKind
        self.enabled = enabled
        self.readiness = readiness
    }
}

public struct ServerHarnessCapability: Codable, Equatable, Sendable {
    public var harness: ServerHarness
    public var modes: SessionModeState?
    public var configOptions: [SessionConfigOption]
}

public struct ServerCapabilities: Codable, Equatable, Sendable {
    public var harnesses: [ServerHarnessCapability]
}

public struct ServerPromptAccepted: Decodable, Equatable, Sendable {
    public var accepted: Bool
    public var sessionId: String
    public var queueItemId: String?
}

public struct ServerPromptQueueItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var sessionId: String
    public var text: String
    public var createdAt: String
    public var updatedAt: String
    public var attachments: [ServerAttachmentRef]?

    init(id: String, sessionId: String, text: String, createdAt: String, updatedAt: String, attachments: [ServerAttachmentRef]? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.attachments = attachments
    }
}

public enum ServerAttachmentKind: String, Codable, Equatable, Sendable {
    case image
    case file
}

/// A reference to an uploaded file (`POST /v1/files`); bytes are fetched via
/// `GET /v1/files/:id`.
public struct ServerAttachmentRef: Codable, Identifiable, Equatable, Sendable {
    public var fileId: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var kind: ServerAttachmentKind

    public var id: String { fileId }

    public init(fileId: String, name: String, mimeType: String, sizeBytes: Int, kind: ServerAttachmentKind) {
        self.fileId = fileId
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.kind = kind
    }
}

public struct ServerFileMetadata: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var sizeBytes: Int
    public var sha256: String
    public var kind: ServerAttachmentKind
    public var createdAt: String

    public var attachmentRef: ServerAttachmentRef {
        ServerAttachmentRef(fileId: id, name: name, mimeType: mimeType, sizeBytes: sizeBytes, kind: kind)
    }
}

public struct ServerProjectLocation: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var folderPath: String
    public var createdAt: String
    public var isGitRepository: Bool?
}

public struct ServerProject: Decodable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var isArchived: Bool
    public var symbolName: String
    public var origin: SessionOrigin
    public var createdAt: String
    public var locations: [ServerProjectLocation]

    public func project(serverId: String = "local") throws -> Project {
        guard let uuid = UUID(uuidString: id) else {
            throw HerdManServerClientError.invalidUUID(id)
        }
        return Project(
            id: uuid,
            serverId: serverId,
            name: name,
            isArchived: isArchived,
            symbolName: symbolName,
            origin: origin,
            createdAt: try ServerDateCoding.date(from: createdAt),
            locations: locations.map { location in
                ProjectLocation(
                    id: location.id,
                    projectId: uuid,
                    serverId: location.serverId,
                    folderPath: location.folderPath,
                    isGitRepository: location.isGitRepository
                )
            }
        )
    }
}

public struct ServerWorktree: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var name: String
    public var branch: String
    public var path: String
    public var createdAt: String
}

public struct ServerSessionUsage: Decodable, Equatable, Sendable {
    public var used: Double?
    public var size: Double?
    public var costAmount: Double?
    public var costCurrency: String?
}

public struct ServerSession: Decodable, Equatable, Sendable {
    public var id: String
    public var projectId: String
    public var serverId: String
    public var harnessId: String
    public var agentSessionId: String?
    public var title: String
    public var origin: SessionOrigin
    public var isArchived: Bool
    public var worktreeName: String?
    public var cwd: String?
    public var createdAt: String
    public var updatedAt: String?
    public var usage: ServerSessionUsage?

    public func chatSession(serverId scopedServerId: String? = nil) throws -> ChatSession {
        guard let uuid = UUID(uuidString: id) else {
            throw HerdManServerClientError.invalidUUID(id)
        }
        guard let projectUUID = UUID(uuidString: projectId) else {
            throw HerdManServerClientError.invalidUUID(projectId)
        }
        return ChatSession(
            id: uuid,
            projectId: projectUUID,
            serverId: scopedServerId ?? serverId,
            harnessId: harnessId,
            agentSessionId: agentSessionId,
            title: title,
            origin: origin,
            isArchived: isArchived,
            worktreeName: worktreeName,
            cwd: cwd,
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
    public var messageId: String?
    public var text: String
    public var createdAt: String
    public var isGenerating: Bool
    public var attachments: [ServerAttachmentRef]? = nil
}

public struct ServerSessionDetail: Decodable, Equatable, Sendable {
    public var session: ServerSession
    public var conversation: [ServerConversationItem]
    public var promptQueue: [ServerPromptQueueItem]
    public var eventCursor: Int

    public init(
        session: ServerSession,
        conversation: [ServerConversationItem],
        promptQueue: [ServerPromptQueueItem] = [],
        eventCursor: Int
    ) {
        self.session = session
        self.conversation = conversation
        self.promptQueue = promptQueue
        self.eventCursor = eventCursor
    }

    enum CodingKeys: String, CodingKey {
        case session
        case conversation
        case promptQueue
        case eventCursor
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        session = try container.decode(ServerSession.self, forKey: .session)
        conversation = try container.decode([ServerConversationItem].self, forKey: .conversation)
        promptQueue = try container.decodeIfPresent([ServerPromptQueueItem].self, forKey: .promptQueue) ?? []
        eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    }
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

    public func info() async throws -> ServerInfo {
        try await get("/v1/info")
    }

    public func updateInfo() async throws -> ServerUpdateInfo {
        try await get("/v1/update")
    }

    public func issuePairingToken() async throws -> ServerPairingToken {
        try await send("/v1/auth/pairing-token", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func capabilities(cwd: String) async throws -> ServerCapabilities {
        let encoded = cwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cwd
        return try await get("/v1/capabilities?cwd=\(encoded)")
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

    public func listProjects() async throws -> [ServerProject] {
        try await get("/v1/projects")
    }

    public func upsertProject(_ project: Project) async throws -> ServerProject {
        let remoteProjects = try await listProjects()
        if remoteProjects.contains(where: { $0.id == project.id.uuidString }) {
            return try await updateProject(project)
        }
        return try await createProject(project)
    }

    public func updateProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects/\(project.id.uuidString)",
            method: "PATCH",
            body: UpdateProjectBody(project: project)
        )
    }

    public func deleteProject(id: UUID) async throws {
        try await sendNoResponse("/v1/projects/\(id.uuidString)", method: "DELETE")
    }

    public func listWorktrees(projectId: UUID) async throws -> [ServerWorktree] {
        try await get("/v1/projects/\(projectId.uuidString)/worktrees")
    }

    public func createWorktree(projectId: UUID, name: String?) async throws -> ServerWorktree {
        try await send(
            "/v1/projects/\(projectId.uuidString)/worktrees",
            method: "POST",
            body: CreateWorktreeBody(name: name)
        )
    }

    public func listSessions() async throws -> [ServerSession] {
        try await get("/v1/sessions")
    }

    public func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        try await get("/v1/sessions/\(id.uuidString)")
    }

    public func sessionEvents(id: UUID) async throws -> [ServerEventEnvelope] {
        try await get("/v1/sessions/\(id.uuidString)/events")
    }

    public func promptQueue(id: UUID) async throws -> [ServerPromptQueueItem] {
        try await get("/v1/sessions/\(id.uuidString)/queue")
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

    /// Marks conversation activity (a finished turn) without touching other
    /// fields — the server orders sessions by this stamp.
    public func touchSession(id: UUID, updatedAt: Date) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)",
            method: "PATCH",
            body: TouchSessionBody(updatedAt: ServerDateCoding.string(from: updatedAt))
        )
    }

    public func deleteSession(id: UUID) async throws {
        try await sendNoResponse("/v1/sessions/\(id.uuidString)", method: "DELETE")
    }

    public func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        try await promptSession(id: id, text: text, attachments: [])
    }

    public func promptSession(id: UUID, text: String, attachments: [ServerAttachmentRef]) async throws -> ServerPromptAccepted {
        try await send(
            "/v1/sessions/\(id.uuidString)/prompt",
            method: "POST",
            body: PromptBody(text: text, attachments: attachments.isEmpty ? nil : attachments)
        )
    }

    public func uploadFile(name: String, mimeType: String, data: Data) async throws -> ServerFileMetadata {
        // Conservative encoding: percent-encode everything non-alphanumeric so
        // names with `&`, `+`, or `=` survive the query round-trip.
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment"
        let response = try await performRaw(
            "/v1/files?name=\(encodedName)",
            method: "POST",
            body: data,
            contentType: mimeType
        )
        return try decoder.decode(ServerFileMetadata.self, from: response)
    }

    public func fileData(id: String) async throws -> Data {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        return try await performRaw("/v1/files/\(encoded)", method: "GET", body: nil, contentType: nil)
    }

    public func updateQueuedPrompt(sessionId: UUID, queueItemId: String, text: String) async throws -> ServerPromptQueueItem {
        try await send(
            "/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)",
            method: "PATCH",
            body: UpdateQueuedPromptBody(text: text)
        )
    }

    public func deleteQueuedPrompt(sessionId: UUID, queueItemId: String) async throws {
        try await sendNoResponse("/v1/sessions/\(sessionId.uuidString)/queue/\(queueItemId)", method: "DELETE")
    }

    public func cancelSession(id: UUID) async throws {
        try await sendNoResponse(
            "/v1/sessions/\(id.uuidString)/cancel",
            method: "POST",
            body: CancelBody()
        )
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

    public func requestShutdown() async throws {
        try await sendNoResponse("/v1/shutdown", method: "POST")
    }

    public func applyServerUpdate() async throws -> ServerUpdateApplied {
        try await send("/v1/update/apply", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func eventStream(since: Int = 0) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = since
                var failures = 0
                while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: try websocketURL(for: "/v1/events/socket?since=\(cursor)"))
                        applyAuthorization(to: &request)
                        let socket = urlSession.webSocketTask(with: request)
                        socket.resume()
                        defer { socket.cancel(with: .goingAway, reason: nil) }
                        failures = 0

                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            guard let data = Self.data(from: message) else { continue }
                            let event = try decoder.decode(ServerEventEnvelope.self, from: data)
                            cursor = max(cursor, event.id)
                            continuation.yield(event)
                        }
                    } catch {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        failures += 1
                        try? await Task.sleep(for: Self.eventReconnectDelay(failures: failures))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func eventReconnectDelay(failures: Int) -> Duration {
        let base = min(5_000, 250 * (1 << min(failures, 5)))
        let jitter = Int.random(in: 0...250)
        return .milliseconds(base + jitter)
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    private func createProject(_ project: Project) async throws -> ServerProject {
        try await send(
            "/v1/projects",
            method: "POST",
            body: CreateProjectBody(project: project)
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

    /// Sibling of `perform` for raw (non-JSON) bodies and responses — file
    /// uploads and downloads.
    private func performRaw(
        _ path: String,
        method: String,
        body: Data?,
        contentType: String?
    ) async throws -> Data {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        applyAuthorization(to: &request)
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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

    private func websocketURL(for path: String) throws -> URL {
        let baseURL = try url(for: path)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HerdManServerClientError.invalidURL(path)
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

private struct PromptBody: Encodable {
    var text: String
    var clientActionId = UUID().uuidString
    var attachments: [ServerAttachmentRef]?
}

private struct UpdateQueuedPromptBody: Encodable {
    var text: String
}

private struct CancelBody: Encodable {
    var clientActionId = UUID().uuidString
}

private struct SetModeBody: Encodable {
    var modeId: String
    var clientActionId = UUID().uuidString
}

private struct SetConfigBody: Encodable {
    var configId: String
    var value: String
    var clientActionId = UUID().uuidString
}

private struct UpdateHarnessBody: Encodable {
    var enabled: Bool
}

private struct CreateProjectBody: Encodable {
    var id: String
    var folderPath: String
    var name: String
    var isArchived: Bool
    var symbolName: String
    var origin: SessionOrigin
    var createdAt: String

    init(project: Project) {
        id = project.id.uuidString
        folderPath = project.folderURL.path
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
        origin = project.origin
        createdAt = ServerDateCoding.string(from: project.createdAt)
    }
}

private struct UpdateProjectBody: Encodable {
    var name: String
    var isArchived: Bool
    var symbolName: String

    init(project: Project) {
        name = project.name
        isArchived = project.isArchived
        symbolName = project.symbolName
    }
}

private struct CreateSessionBody: Encodable {
    var id: String
    var projectId: String
    var harnessId: String
    var agentSessionId: String?
    var title: String
    var origin: SessionOrigin
    var isArchived: Bool
    var worktreeName: String?
    var createdAt: String
    var updatedAt: String?

    init(session: ChatSession) {
        id = session.id.uuidString
        projectId = session.projectId.uuidString
        harnessId = session.harnessId
        agentSessionId = session.agentSessionId
        title = session.title
        origin = session.origin
        isArchived = session.isArchived
        worktreeName = session.worktreeName
        createdAt = ServerDateCoding.string(from: session.createdAt)
        updatedAt = session.updatedAt.map(ServerDateCoding.string)
    }
}

private struct CreateWorktreeBody: Encodable {
    var name: String?
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

private struct TouchSessionBody: Encodable {
    var updatedAt: String
}
