import Foundation
import ACPKit
import ACPAgents

public struct ServerAgentService: AgentServicing {
    private let client: any HerdManServerClienting
    private let fallback: any AgentServicing

    public init(
        client: any HerdManServerClienting,
        fallback: any AgentServicing = AgentService()
    ) {
        self.client = client
        self.fallback = fallback
    }

    public func discoverAgents() async -> [DiscoveredAgent] {
        do {
            return try await client.listHarnesses()
                .filter { $0.enabled && $0.readiness.state == "ready" }
                .map(\.discoveredAgent)
        } catch {
            return await fallback.discoverAgents()
        }
    }

    public func discoverAllHarnesses() async -> [DiscoveredAgent] {
        do {
            return try await client.listHarnesses().map(\.discoveredAgent)
        } catch {
            return await fallback.discoverAllHarnesses()
        }
    }

    public func launch(
        _ agent: DiscoveredAgent,
        workingDirectory: URL,
        delegate: (any ACPClientDelegate)?
    ) async throws -> ACPClient {
        try await fallback.launch(agent, workingDirectory: workingDirectory, delegate: delegate)
    }

    public func listSessions(for agent: DiscoveredAgent) async throws -> [SessionInfo] {
        do {
            let workspaces = try await client.listWorkspaces()
            let workspacePaths = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0.folderPath) })
            return try await client.listSessions()
                .filter { $0.harnessId == agent.id }
                .compactMap { session in
                    guard let cwd = workspacePaths[session.workspaceId] else { return nil }
                    return SessionInfo(
                        sessionId: session.agentSessionId ?? session.id,
                        cwd: cwd,
                        title: session.title,
                        updatedAt: session.updatedAt ?? session.createdAt
                    )
                }
        } catch {
            return try await fallback.listSessions(for: agent)
        }
    }
}

private extension ServerHarness {
    var discoveredAgent: DiscoveredAgent {
        DiscoveredAgent(
            id: id,
            name: name,
            source: source == "path" ? .path : .registry,
            method: launchMethod,
            readiness: readiness.agentReadiness,
            symbolName: symbolName
        )
    }

    var launchMethod: LaunchMethod {
        switch launchKind {
        case "npx": .npx
        case "uvx": .uvx
        case "executable": .executable
        default: .binary
        }
    }
}

private extension ServerHarnessReadiness {
    var agentReadiness: AgentReadiness {
        state == "ready" ? .ready : .unavailable(detail ?? "Unavailable")
    }
}
