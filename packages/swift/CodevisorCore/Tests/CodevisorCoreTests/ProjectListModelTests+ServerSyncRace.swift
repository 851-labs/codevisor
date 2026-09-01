import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
extension ProjectListModelTests {
    @Test("A live creation event cannot let an older snapshot remove the session")
    func liveCreationEventPreservesSessionAgainstOlderSnapshot() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/live-created-session"))
        let fakeServer = ServerSyncRaceClient(projects: [serverProject(from: project)])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil { model.projects.contains { $0.id == project.id } }

        let projectListRelease = Latch()
        let sessionSnapshotCaptured = Latch()
        await fakeServer.setListDelay { await projectListRelease.wait() }
        await fakeServer.setSessionListObservation { await sessionSnapshotCaptured.open() }

        let session = model.newSession(
            in: project,
            title: "New Chat",
            harnessId: "",
            syncToServer: false
        )
        let staleRefresh = Task { await model.refreshFromServer() }
        await sessionSnapshotCaptured.wait()

        let remote = try await fakeServer.upsertSession(session)
        let payload: JSONValue = .object([
            "id": .string(remote.id),
            "projectId": .string(remote.projectId),
            "serverId": .string(remote.serverId),
            "harnessId": .string(remote.harnessId),
            "title": .string(remote.title),
            "origin": .string(remote.origin.rawValue),
            "isArchived": .bool(remote.isArchived),
            "createdAt": .string(remote.createdAt),
        ])
        _ = await model.applyServerSessionEvent(
            ServerEventEnvelope(
                id: 1,
                serverId: "local",
                kind: "session.created",
                subjectId: session.id.uuidString,
                createdAt: remote.createdAt,
                payload: payload
            ),
            serverId: "local"
        )

        await projectListRelease.open()
        _ = await staleRefresh.value
        #expect(model.sessions.contains { $0.id == session.id })

        // A later snapshot that contains the row retires the optimistic marker
        // and adopts the normal authoritative copy without a duplicate.
        _ = await model.refreshFromServer()
        #expect(model.sessions.filter { $0.id == session.id }.count == 1)
    }

    @Test("A successful upsert cannot let an older snapshot remove the session")
    func successfulUpsertPreservesSessionAgainstOlderSnapshot() async throws {
        let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/upserted-session"))
        let fakeServer = ServerSyncRaceClient(projects: [serverProject(from: project)])
        let model = ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore()),
            serverClient: fakeServer
        )
        try await waitUntil { model.projects.contains { $0.id == project.id } }

        let projectListRelease = Latch()
        let sessionSnapshotCaptured = Latch()
        let sessionUpsertRelease = Latch()
        await fakeServer.setListDelay { await projectListRelease.wait() }
        await fakeServer.setSessionListObservation { await sessionSnapshotCaptured.open() }
        await fakeServer.setSessionUpsertDelay { await sessionUpsertRelease.wait() }

        let session = model.newSession(
            in: project,
            title: "New Chat",
            harnessId: "",
            syncToServer: true
        )
        let staleRefresh = Task { await model.refreshFromServer() }
        await sessionSnapshotCaptured.wait()

        await sessionUpsertRelease.open()
        try await waitUntilAsync {
            await fakeServer.hasUpsertedSession(id: session.id)
        }
        await projectListRelease.open()
        _ = await staleRefresh.value
        #expect(model.sessions.contains { $0.id == session.id })

        _ = await model.refreshFromServer()
        #expect(model.sessions.filter { $0.id == session.id }.count == 1)
    }
}

private actor ServerSyncRaceClient: CodevisorServerClienting {
    private var projects: [ServerProject]
    private var sessions: [ServerSession] = []
    private var upsertedSessionIDs: Set<String> = []
    private var listDelay: (@Sendable () async -> Void)?
    private var sessionListObservation: (@Sendable () async -> Void)?
    private var sessionUpsertDelay: (@Sendable () async -> Void)?

    init(projects: [ServerProject]) {
        self.projects = projects
    }

    func setListDelay(_ delay: @escaping @Sendable () async -> Void) {
        listDelay = delay
    }

    func setSessionListObservation(_ observation: @escaping @Sendable () async -> Void) {
        sessionListObservation = observation
    }

    func setSessionUpsertDelay(_ delay: @escaping @Sendable () async -> Void) {
        sessionUpsertDelay = delay
    }

    func hasUpsertedSession(id: UUID) -> Bool {
        upsertedSessionIDs.contains(id.uuidString)
    }

    func health() async throws -> ServerHealth {
        ServerHealth(ok: true, version: "0.1.0", database: "ready")
    }

    func info() async throws -> ServerInfo { fatalError("unused") }

    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        fatalError("unused")
    }

    func issuePairingToken() async throws -> ServerPairingToken { fatalError("unused") }

    func capabilities(cwd: String) async throws -> ServerCapabilities {
        ServerCapabilities(harnesses: [])
    }

    func listHarnesses() async throws -> [ServerHarness] { [] }

    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness {
        fatalError("unused")
    }

    func listProjects() async throws -> [ServerProject] {
        if let listDelay { await listDelay() }
        return projects
    }

    func upsertProject(_ project: Project) async throws -> ServerProject {
        let remote = serverProject(from: project)
        projects.removeAll { $0.id == remote.id }
        projects.append(remote)
        return remote
    }

    func updateProject(_ project: Project) async throws -> ServerProject {
        try await upsertProject(project)
    }

    func deleteProject(id: UUID) async throws {
        projects.removeAll { $0.id == id.uuidString }
    }

    func listSessions() async throws -> [ServerSession] {
        let snapshot = sessions
        if let sessionListObservation { await sessionListObservation() }
        return snapshot
    }

    func sessionDetail(id: UUID) async throws -> ServerSessionDetail {
        fatalError("unused")
    }

    func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        if let sessionUpsertDelay { await sessionUpsertDelay() }
        let remote = serverSession(from: session)
        upsertedSessionIDs.insert(remote.id)
        sessions.removeAll { $0.id == remote.id }
        sessions.append(remote)
        return remote
    }

    func updateSession(_ session: ChatSession) async throws -> ServerSession {
        try await upsertSession(session)
    }

    func markSessionRead(id: UUID, throughSequence: Int) async throws -> ServerSession? {
        sessions.first { $0.id == id.uuidString }
    }

    func deleteSession(id: UUID) async throws {
        sessions.removeAll { $0.id == id.uuidString }
    }

    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }

    func cancelSession(id: UUID) async throws {}

    func setSessionMode(id: UUID, modeId: String) async throws {}

    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}

    nonisolated func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
