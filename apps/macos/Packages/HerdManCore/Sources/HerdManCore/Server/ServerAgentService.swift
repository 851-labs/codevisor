import Foundation
import ACPKit

/// Server-backed access to the harness catalog and importable sessions. The
/// HerdMan server is the only agent backend; there is no in-process launch
/// path.
public protocol HarnessServicing: Sendable {
    /// Harnesses that are enabled and ready to start a session. Best-effort:
    /// an unreachable server reads as "none ready" (used by the importer).
    func readyHarnesses() async -> [ServerHarness]
    /// The full catalog, including unavailable harnesses (for Settings and
    /// onboarding). Throws when the server can't be reached so callers can
    /// distinguish "unreachable" from "nothing installed".
    func allHarnesses() async throws -> [ServerHarness]
    /// The full catalog after the server re-resolves its PATH — finds CLIs
    /// installed after the server started. Throws like `allHarnesses()`.
    func rescanHarnesses() async throws -> [ServerHarness]
    /// Importable sessions previously run by the given harness.
    func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo]
}

public extension HarnessServicing {
    /// Default for fakes/preview services with a fixed catalog: rescanning
    /// can't change anything, so it's a plain list. `ServerHarnessService`
    /// overrides this with the server's PATH-refreshing endpoint.
    func rescanHarnesses() async throws -> [ServerHarness] {
        try await allHarnesses()
    }
}

public struct ServerHarnessService: HarnessServicing {
    private let client: any HerdManServerClienting

    public init(client: any HerdManServerClienting) {
        self.client = client
    }

    public func readyHarnesses() async -> [ServerHarness] {
        ((try? await allHarnesses()) ?? []).filter { $0.enabled && $0.isReady }
    }

    public func allHarnesses() async throws -> [ServerHarness] {
        try await client.listHarnesses()
    }

    public func rescanHarnesses() async throws -> [ServerHarness] {
        try await client.rescanHarnesses()
    }

    public func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
        // The harness's own on-disk sessions: the whole point of workspace
        // suggestions and chat import is surfacing what the user did BEFORE
        // HerdMan, which HerdMan's sessions table (used as a fallback for
        // older servers below) cannot contain on a fresh install.
        do {
            return try await client.listAgentSessions(harnessId: harnessId)
        } catch HerdManServerClientError.httpStatus(404, _) {
            return try await herdmanSessions(forHarnessId: harnessId)
        }
    }

    /// Legacy fallback for servers without the agent-sessions endpoint:
    /// HerdMan's own session records.
    private func herdmanSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
        let projects = try await client.listProjects()
        let projectLocations = Dictionary(
            uniqueKeysWithValues: projects.map { ($0.id, $0.locations) }
        )
        return try await client.listSessions()
            .filter { $0.harnessId == harnessId }
            .compactMap { session in
                // The server resolves cwd (project folder or worktree);
                // fall back to the project's location on the session's server.
                let locationPath = projectLocations[session.projectId]?
                    .first { $0.serverId == session.serverId }?.folderPath
                guard let cwd = session.cwd ?? locationPath else { return nil }
                return SessionInfo(
                    sessionId: session.agentSessionId ?? session.id,
                    cwd: cwd,
                    title: session.title,
                    updatedAt: session.updatedAt ?? session.createdAt
                )
            }
    }
}

public extension ServerHarness {
    var isReady: Bool { readiness.state == "ready" }
}

extension ServerHarness: Identifiable {}
