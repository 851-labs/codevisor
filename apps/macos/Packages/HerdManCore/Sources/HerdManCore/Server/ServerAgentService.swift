import Foundation
import ACPKit

/// Server-backed access to the harness catalog and importable sessions. The
/// HerdMan server is the only agent backend; there is no in-process launch
/// path.
public protocol HarnessServicing: Sendable {
    /// Harnesses that are enabled and ready to start a session.
    func readyHarnesses() async -> [ServerHarness]
    /// The full catalog, including unavailable harnesses (for Settings and
    /// onboarding).
    func allHarnesses() async -> [ServerHarness]
    /// Importable sessions previously run by the given harness.
    func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo]
}

public struct ServerHarnessService: HarnessServicing {
    private let client: any HerdManServerClienting

    public init(client: any HerdManServerClienting) {
        self.client = client
    }

    public func readyHarnesses() async -> [ServerHarness] {
        await allHarnesses().filter { $0.enabled && $0.isReady }
    }

    public func allHarnesses() async -> [ServerHarness] {
        (try? await client.listHarnesses()) ?? []
    }

    public func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
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
