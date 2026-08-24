import ACPKit
import Foundation

@testable import CodevisorCore

/// A fake server whose event stream and list endpoints are test-driven.
/// Shared by the MachineController suites (sync, panes, self-updates).
final class SyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
    private let lock = NSLock()
    private var _projects: [ServerProject]
    private var _sessions: [ServerSession]
    private var _workspaces: [ServerWorkspace]
    private var _panes: [ServerWorkspacePane]?
    private var continuations: [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation] = []
    private var emittedEvents: [ServerEventEnvelope] = []
    private var nextEventId = 1
    private var _listSessionCallCount = 0
    private var _workspaceSnapshotCallCount = 0
    private var _paneUpsertDelayNanoseconds: UInt64 = 0
    private var _panePromotionDelayNanoseconds: UInt64 = 0
    private var _paneCloseDelayNanoseconds: UInt64 = 0
    private var _paneMutationLog: [String] = []

    init(
        projects: [ServerProject],
        sessions: [ServerSession],
        workspaces: [ServerWorkspace] = [],
        panes: [ServerWorkspacePane]? = nil
    ) {
        _projects = projects
        _sessions = sessions
        _workspaces = workspaces
        _panes = panes
    }

    func setSessions(_ sessions: [ServerSession]) {
        lock.withLock { _sessions = sessions }
    }

    func setProjects(_ projects: [ServerProject]) {
        lock.withLock { _projects = projects }
    }

    func setWorkspaces(_ workspaces: [ServerWorkspace]) {
        lock.withLock { _workspaces = workspaces }
    }

    func setPanes(_ panes: [ServerWorkspacePane]) {
        lock.withLock { _panes = panes }
    }

    func configurePanePromotionDelay(nanoseconds: UInt64) {
        lock.withLock { _panePromotionDelayNanoseconds = nanoseconds }
    }

    func configurePaneUpsertDelay(nanoseconds: UInt64) {
        lock.withLock { _paneUpsertDelayNanoseconds = nanoseconds }
    }

    func configurePaneCloseDelay(nanoseconds: UInt64) {
        lock.withLock { _paneCloseDelayNanoseconds = nanoseconds }
    }

    var listSessionCallCount: Int { lock.withLock { _listSessionCallCount } }
    /// How many event-stream subscriptions are currently attached.
    var eventStreamSubscriberCount: Int { lock.withLock { continuations.count } }
    var workspaceSnapshotCallCount: Int { lock.withLock { _workspaceSnapshotCallCount } }
    var sessions: [ServerSession] { lock.withLock { _sessions } }
    var workspaces: [ServerWorkspace] { lock.withLock { _workspaces } }
    var workspacePanes: [ServerWorkspacePane]? { lock.withLock { _panes } }
    var paneMutationLog: [String] { lock.withLock { _paneMutationLog } }

    func emit(kind: String, subjectId: String, payload: JSONValue = .null) {
        let (event, targets):
            (ServerEventEnvelope, [AsyncThrowingStream<ServerEventEnvelope, any Error>.Continuation]) = lock.withLock {
                let event = ServerEventEnvelope(
                    id: nextEventId,
                    serverId: "local",
                    kind: kind,
                    subjectId: subjectId,
                    createdAt: "2026-06-30T00:00:02.000Z",
                    payload: payload
                )
                nextEventId += 1
                emittedEvents.append(event)
                return (event, continuations)
            }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Mirrors the real server: replays the event log from `since`, then
    /// streams new events.
    func eventStream(since: Int) -> AsyncThrowingStream<ServerEventEnvelope, any Error> {
        AsyncThrowingStream { continuation in
            let backlog: [ServerEventEnvelope] = lock.withLock {
                continuations.append(continuation)
                return emittedEvents.filter { $0.id > since }
            }
            for event in backlog {
                continuation.yield(event)
            }
        }
    }

    func listProjects() async throws -> [ServerProject] { lock.withLock { _projects } }
    func listSessions() async throws -> [ServerSession] {
        lock.withLock {
            _listSessionCallCount += 1
            return _sessions
        }
    }
    func listWorkspaces() async throws -> [ServerWorkspace]? { lock.withLock { _workspaces } }
    func workspaceSnapshot() async throws -> ServerWorkspaceSnapshot? {
        lock.withLock {
            _workspaceSnapshotCallCount += 1
            guard let panes = _panes else { return nil }
            return ServerWorkspaceSnapshot(workspaces: _workspaces, panes: panes)
        }
    }
    func upsertWorkspace(_ workspace: ServerWorkspace) async throws -> ServerWorkspace? {
        lock.withLock {
            _workspaces.removeAll {
                $0.id.caseInsensitiveCompare(workspace.id) == .orderedSame
            }
            _workspaces.append(workspace)
            return workspace
        }
    }
    func listWorkspacePanes() async throws -> [ServerWorkspacePane]? { lock.withLock { _panes } }
    func upsertWorkspacePane(_ pane: ServerWorkspacePane) async throws -> ServerWorkspacePane? {
        let delay = lock.withLock {
            _paneMutationLog.append("upsert")
            return _paneUpsertDelayNanoseconds
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock { () -> ServerWorkspacePane? in
            guard _panes != nil else { return nil }
            _panes?.removeAll { $0.id.caseInsensitiveCompare(pane.id) == .orderedSame }
            _panes?.append(pane)
            return pane
        }
    }

    func promoteWorkspacePaneToChat(
        _ pane: ServerWorkspacePane,
        session: ChatSession
    ) async throws -> ServerWorkspacePanePromotion? {
        let delay = lock.withLock { _panePromotionDelayNanoseconds }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock {
            guard
                let paneIndex = _panes?.firstIndex(where: {
                    $0.id.caseInsensitiveCompare(pane.id) == .orderedSame
                }),
                let sessionIndex = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { return nil }
            var promoted = pane
            promoted.revision = (_panes?[paneIndex].revision ?? 0) + 1
            _panes?[paneIndex] = promoted
            _sessions[sessionIndex].workspaceId = pane.workspaceId
            return ServerWorkspacePanePromotion(
                pane: promoted,
                session: _sessions[sessionIndex]
            )
        }
    }

    func deleteWorkspacePane(workspaceId _: UUID, paneId: UUID) async throws {
        lock.withLock {
            _panes?.removeAll {
                $0.id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
            }
        }
    }

    func closeWorkspacePane(workspaceId: UUID, paneId: UUID) async throws -> ServerWorkspacePane? {
        let delay = lock.withLock {
            _paneMutationLog.append("close")
            return _paneCloseDelayNanoseconds
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return lock.withLock { () -> ServerWorkspacePane? in
            guard let panes = _panes else { return nil }
            let workspacePaneIndices = panes.indices.filter {
                panes[$0].workspaceId.caseInsensitiveCompare(workspaceId.uuidString) == .orderedSame
            }
            guard
                let index = workspacePaneIndices.first(where: {
                    panes[$0].id.caseInsensitiveCompare(paneId.uuidString) == .orderedSame
                })
            else { return nil }
            if workspacePaneIndices.count > 1 {
                _panes?.remove(at: index)
                return nil
            }
            var replacement = panes[index]
            if replacement.paneType != "new-tab" || replacement.resourceId != nil {
                replacement.providerId = "codevisor"
                replacement.paneType = "new-tab"
                replacement.title = "New tab"
                replacement.resourceKind = nil
                replacement.resourceId = nil
                replacement.metadata = nil
                replacement.revision = (replacement.revision ?? 0) + 1
                _panes?[index] = replacement
            }
            return replacement
        }
    }

    // MARK: - Simulated server versioning / self-update

    private var currentVersion = "0.1.0"
    private var latestVersion = "0.1.0"
    private var installedVersionAfterUpdate: String?
    private var updateApplied = false
    private var bootId = "boot-before-update"
    private var downtimeRemaining = 0
    private var _appliedUpdates = 0
    private var _updateInfoChannels: [ServerUpdateChannel] = []
    private var _updateInfoRefreshes: [Bool] = []
    private var _appliedChannels: [ServerUpdateChannel] = []
    private var _busy = false
    private var currentBuildNumber: Int?
    private var targetBuildNumber: Int?
    private var applyFailureMessage: String?
    private var lastApply: ServerUpdateApplyState?

    struct ServerDownError: Error {}

    var appliedUpdates: Int { lock.withLock { _appliedUpdates } }
    var updateInfoChannels: [ServerUpdateChannel] { lock.withLock { _updateInfoChannels } }
    var updateInfoRefreshes: [Bool] { lock.withLock { _updateInfoRefreshes } }
    var appliedChannels: [ServerUpdateChannel] { lock.withLock { _appliedChannels } }

    /// Makes the fake report an available update to `latest`.
    func configureUpdate(
        current: String,
        latest: String,
        installedVersion: String? = nil,
        currentBuildNumber: Int? = nil,
        targetBuildNumber: Int? = nil
    ) {
        lock.withLock {
            currentVersion = current
            latestVersion = latest
            installedVersionAfterUpdate = installedVersion
            self.currentBuildNumber = currentBuildNumber
            self.targetBuildNumber = targetBuildNumber
            applyFailureMessage = nil
            lastApply = nil
            updateApplied = false
            bootId = "boot-before-update"
        }
    }

    /// Makes `applyServerUpdate()` decline as busy (chats still running).
    func configureBusy(_ value: Bool) {
        lock.withLock { _busy = value }
    }

    /// Makes the next apply accept the handoff but fail on the machine:
    /// nothing restarts and updateInfo starts reporting the failure.
    func configureApplyFailure(message: String) {
        lock.withLock { applyFailureMessage = message }
    }

    func health() async throws -> ServerHealth {
        lock.withLock {
            ServerHealth(
                ok: true,
                version: currentVersion,
                database: "ready",
                bootId: bootId,
                buildNumber: currentBuildNumber
            )
        }
    }
    func info() async throws -> ServerInfo {
        let version: String = try lock.withLock {
            if downtimeRemaining > 0 {
                downtimeRemaining -= 1
                throw ServerDownError()
            }
            return currentVersion
        }
        return ServerInfo(
            id: "local", name: "Local", kind: "local", version: version, platform: "darwin", bindHost: "127.0.0.1")
    }
    func updateInfo(refresh: Bool, channel: ServerUpdateChannel) async throws -> ServerUpdateInfo {
        lock.withLock {
            _updateInfoChannels.append(channel)
            _updateInfoRefreshes.append(refresh)
            return ServerUpdateInfo(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                updateAvailable: !updateApplied && currentVersion != latestVersion,
                channel: channel.rawValue,
                checkedAt: nil,
                migrationState: "idle",
                currentBuildNumber: currentBuildNumber,
                latestBuildNumber: targetBuildNumber,
                lastApply: lastApply
            )
        }
    }
    func applyServerUpdate(channel: ServerUpdateChannel) async throws -> ServerUpdateApplied {
        lock.withLock {
            _appliedChannels.append(channel)
            _appliedUpdates += 1
            if _busy {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion, reason: "busy")
            }
            guard currentVersion != latestVersion else {
                return ServerUpdateApplied(accepted: false, targetVersion: currentVersion)
            }
            if let applyFailureMessage {
                // The handoff was accepted but the machine's unattended
                // install failed: nothing restarts, and the failure
                // surfaces through updateInfo's lastApply.
                lastApply = ServerUpdateApplyState(
                    state: "failed",
                    message: applyFailureMessage,
                    targetVersion: latestVersion,
                    at: "2026-06-30T00:00:01.000Z"
                )
                return ServerUpdateApplied(
                    accepted: true,
                    targetVersion: latestVersion,
                    targetBuildNumber: targetBuildNumber
                )
            }
            // The server restarts: unreachable for a few probes, then back on
            // the new version.
            downtimeRemaining = 3
            let targetVersion = latestVersion
            currentVersion = installedVersionAfterUpdate ?? latestVersion
            if let targetBuildNumber { currentBuildNumber = targetBuildNumber }
            updateApplied = true
            bootId = "boot-after-update"
            return ServerUpdateApplied(
                accepted: true,
                targetVersion: targetVersion,
                targetBuildNumber: targetBuildNumber
            )
        }
    }
    func issuePairingToken() async throws -> ServerPairingToken {
        ServerPairingToken(token: "hm_test", createdAt: "2026-06-30T00:00:00.000Z")
    }
    func capabilities(cwd: String) async throws -> ServerCapabilities { ServerCapabilities(harnesses: []) }
    func listHarnesses() async throws -> [ServerHarness] { [] }
    func setHarnessEnabled(id: String, enabled: Bool) async throws -> ServerHarness { fatalError("unused") }
    func upsertProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func updateProject(_ project: Project) async throws -> ServerProject { fatalError("unused") }
    func deleteProject(id: UUID) async throws {}
    func sessionDetail(id: UUID) async throws -> ServerSessionDetail { fatalError("unused") }
    func upsertSession(_ session: ChatSession) async throws -> ServerSession {
        lock.withLock {
            guard
                let index = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { fatalError("Missing fake session") }
            return _sessions[index]
        }
    }
    func upsertSession(_ session: ChatSession, workspaceId: UUID?) async throws -> ServerSession {
        lock.withLock {
            guard
                let index = _sessions.firstIndex(where: {
                    UUID(uuidString: $0.id) == session.id
                })
            else { fatalError("Missing fake session") }
            _sessions[index].workspaceId = workspaceId?.uuidString
            if let workspaceId, _panes != nil,
                _panes?.contains(where: {
                    $0.resourceKind == "session"
                        && $0.resourceId?.caseInsensitiveCompare(session.id.uuidString) == .orderedSame
                }) == false
            {
                _panes?.append(
                    ServerWorkspacePane(
                        id: session.id.uuidString,
                        workspaceId: workspaceId.uuidString,
                        providerId: "codevisor",
                        paneType: "chat",
                        title: _sessions[index].title,
                        resourceKind: "session",
                        resourceId: session.id.uuidString,
                        createdAt: _sessions[index].createdAt
                    )
                )
            }
            return _sessions[index]
        }
    }
    func updateSession(_ session: ChatSession) async throws -> ServerSession { fatalError("unused") }
    func deleteSession(id: UUID) async throws {}
    func promptSession(id: UUID, text: String) async throws -> ServerPromptAccepted {
        ServerPromptAccepted(accepted: true, sessionId: id.uuidString)
    }
    func cancelSession(id: UUID) async throws {}
    func setSessionMode(id: UUID, modeId: String) async throws {}
    func setSessionConfig(id: UUID, configId: String, value: String) async throws {}
}
