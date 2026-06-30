import Foundation
import ACPKit
import ACPAgents

/// A session discovered in a harness, tagged with which harness it belongs to.
public struct ImportedSession: Sendable, Equatable {
    public let harnessId: String
    public let info: SessionInfo

    public init(harnessId: String, info: SessionInfo) {
        self.harnessId = harnessId
        self.info = info
    }
}

/// Fetches sessions from every installed harness via `session/list`.
public struct SessionImporter: Sendable {
    private let agentService: any AgentServicing

    public init(agentService: any AgentServicing) {
        self.agentService = agentService
    }

    /// Lists sessions across all ready harnesses. Failures per harness are ignored.
    public func fetchAll() async -> [ImportedSession] {
        let agents = await agentService.discoverAgents().filter { $0.readiness.isReady }
        var result: [ImportedSession] = []
        for agent in agents {
            guard let infos = try? await agentService.listSessions(for: agent) else { continue }
            result.append(contentsOf: infos.map { ImportedSession(harnessId: agent.id, info: $0) })
        }
        return result
    }
}
