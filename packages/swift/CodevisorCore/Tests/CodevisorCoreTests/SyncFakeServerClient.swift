import ACPKit
import Foundation

@testable import CodevisorCore

/// A fake server whose event stream and list endpoints are test-driven.
/// Shared by the MachineController suites (sync, panes, self-updates).
final class SyncFakeServerClient: CodevisorServerClienting, @unchecked Sendable {
    var _infoCloudDeviceId: String?
    /// Tests that need capability responses (or to delay them) install one.
    var capabilitiesHandler: (@Sendable (String) async throws -> ServerCapabilities)?
    var resolvedCapabilitiesHandler: (@Sendable (String, String, [String: String]) async throws -> ServerCapabilities)?

    let lock = NSLock()
    private var _projects: [ServerProject]
    var _sessions: [ServerSession]
    private var _workspaces: [ServerWorkspace]
    var _panes: [ServerWorkspacePane]?
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

    var currentVersion = "0.1.0"
    var latestVersion = "0.1.0"
    var installedVersionAfterUpdate: String?
    var updateApplied = false
    var bootId = "boot-before-update"
    var downtimeRemaining = 0
    var _infoId = "local"
    var _appliedUpdates = 0
    var _updateInfoChannels: [ServerUpdateChannel] = []
    var _updateInfoRefreshes: [Bool] = []
    var _appliedChannels: [ServerUpdateChannel] = []
    var _busy = false
    var currentBuildNumber: Int?
    var targetBuildNumber: Int?
    var applyFailureMessage: String?
    var lastApply: ServerUpdateApplyState?
    var _harnesses: [ServerHarness] = []
    var _pluginUpdates: [ServerPluginUpdateStatus] = []
    var _operationLog: [String] = []
    var _harnessesSyncApplied: [String] = []
    var _syncEntries: [String: [ServerSyncEntry]] = [:]
    var _skillBlobs: [String: Data] = [:]
    var _wantedSkills: [(directoryName: String, hash: String)] = []
    var _appliedSkillHashes: Set<String> = []

    struct ServerDownError: Error {}
}
