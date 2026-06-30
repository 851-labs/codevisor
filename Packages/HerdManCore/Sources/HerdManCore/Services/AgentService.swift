import Foundation
import ACPKit
import ACPAgents

/// High-level access to local ACP agents: discovery and launching.
public protocol AgentServicing: Sendable {
    /// The harnesses that are installed and ready to launch right now.
    func discoverAgents() async -> [DiscoveredAgent]
    /// Every known harness — installed or not — for catalog/management UI.
    func discoverAllHarnesses() async -> [DiscoveredAgent]
    func launch(
        _ agent: DiscoveredAgent,
        workingDirectory: URL,
        delegate: (any ACPClientDelegate)?
    ) async throws -> ACPClient
    /// Launches the harness briefly and returns its known sessions via
    /// `session/list` (across all working directories).
    func listSessions(for agent: DiscoveredAgent) async throws -> [SessionInfo]
}

public extension AgentServicing {
    /// By default the full catalog is just the installed harnesses; the live
    /// `AgentService` overrides this to also surface not-installed harnesses.
    func discoverAllHarnesses() async -> [DiscoveredAgent] {
        await discoverAgents()
    }
}

/// Default `AgentServicing` that surfaces only the harnesses actually installed
/// on the machine (catalog CLIs plus `*-acp` adapters on PATH) and launches
/// them via `ACPAgents`.
public struct AgentService: AgentServicing {
    private let discovery: HarnessDiscovery
    private let launcher: AgentLauncher

    public init(
        discovery: HarnessDiscovery = HarnessDiscovery(),
        launcher: AgentLauncher = AgentLauncher()
    ) {
        self.discovery = discovery
        self.launcher = launcher
    }

    public func discoverAgents() async -> [DiscoveredAgent] {
        await discovery.installed()
    }

    public func discoverAllHarnesses() async -> [DiscoveredAgent] {
        await discovery.discoverAll()
    }

    public func launch(
        _ agent: DiscoveredAgent,
        workingDirectory: URL,
        delegate: (any ACPClientDelegate)?
    ) async throws -> ACPClient {
        try await launcher.launch(agent, workingDirectory: workingDirectory, delegate: delegate)
    }

    public func listSessions(for agent: DiscoveredAgent) async throws -> [SessionInfo] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let client = try await launcher.launch(agent, workingDirectory: home, delegate: nil)
        defer { Task { await client.close() } }
        _ = try await client.initialize(InitializeRequest(
            protocolVersion: .acpProtocolVersion,
            clientInfo: Implementation(name: "HerdMan", version: "1.0")
        ))
        var all: [SessionInfo] = []
        var cursor: String?
        repeat {
            let response = try await client.listSessions(ListSessionsRequest(cursor: cursor))
            all.append(contentsOf: response.sessions)
            cursor = response.nextCursor
        } while cursor != nil
        return all
    }
}
