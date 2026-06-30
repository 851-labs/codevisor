import Foundation
import HerdManCore
import ACPKit
import ACPAgents

/// Warms the `ConfigOptionCache` on app boot by briefly connecting to each
/// installed harness to fetch its model/reasoning options, so the composer
/// pickers are populated instantly (stale-while-revalidate).
@MainActor
struct ConfigPrefetcher {
    let agentService: any AgentServicing
    let cache: ConfigOptionCache

    /// Fetches and caches config for any installed harness without cached data.
    func warmMissing() async {
        let agents = await agentService.discoverAgents()
        let cwd = FileManager.default.homeDirectoryForCurrentUser
        for agent in agents where agent.readiness.isReady && cache.options(forHarness: agent.id).isEmpty {
            await warm(agent, cwd: cwd)
        }
    }

    private func warm(_ agent: DiscoveredAgent, cwd: URL) async {
        // Retain the delegate for the lifetime of the warm connection.
        let delegate = AppClientDelegate()
        do {
            let client = try await agentService.launch(agent, workingDirectory: cwd, delegate: delegate)
            _ = try await client.initialize(InitializeRequest(
                protocolVersion: .acpProtocolVersion,
                clientCapabilities: ClientCapabilities(
                    fs: FileSystemCapabilities(readTextFile: true, writeTextFile: true)
                ),
                clientInfo: Implementation(name: "HerdMan", version: "1.0")
            ))
            let session = try await client.newSession(NewSessionRequest(cwd: cwd.path, mcpServers: []))
            cache.store(session.configOptions ?? [], forHarness: agent.id)
            await client.close()
        } catch {
            // Warming is best-effort; ignore failures.
        }
        _ = delegate
    }
}
