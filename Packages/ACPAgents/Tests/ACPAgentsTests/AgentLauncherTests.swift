import Foundation
import Testing
@testable import ACPAgents
import ACPKit

@Suite("AgentLauncher")
struct AgentLauncherTests {
    private func readyAgent() -> DiscoveredAgent {
        DiscoveredAgent(
            id: "x",
            name: "X",
            source: .registry,
            method: .npx,
            readiness: .ready,
            launchSpec: ProcessSpec(executableURL: URL(fileURLWithPath: "/bin/npx"), arguments: ["-y", "x"])
        )
    }

    @Test("Launches a ready agent and returns a started client")
    func launchReady() async throws {
        let provider = FakeTransportProvider()
        let launcher = AgentLauncher(transportProvider: provider)
        let client = try await launcher.launch(readyAgent())

        // The returned client should be wired to the provided transport: a
        // request it sends should appear on the transport's `sent` stream.
        let task = Task { try? await client.initialize(InitializeRequest(protocolVersion: 1)) }
        var sawInitialize = false
        for await data in provider.transport.sent {
            if let inbound = try? JSONRPCInbound(data: data), case .request(let request) = inbound,
               request.method == ACPMethod.initialize {
                sawInitialize = true
                break
            }
        }
        task.cancel()
        #expect(sawInitialize)
    }

    @Test("Applies the working directory override to the spec")
    func workingDirectory() async throws {
        let provider = FakeTransportProvider()
        let launcher = AgentLauncher(transportProvider: provider)
        _ = try await launcher.launch(readyAgent(), workingDirectory: URL(fileURLWithPath: "/tmp/work"))
        #expect(provider.lastSpec?.currentDirectoryURL?.path == "/tmp/work")
    }

    @Test("Throws when the agent is not ready")
    func notReady() async {
        let provider = FakeTransportProvider()
        let launcher = AgentLauncher(transportProvider: provider)
        let agent = DiscoveredAgent(id: "x", name: "X", source: .registry, method: .npx, readiness: .needsRunner("npx"))
        await #expect(throws: AgentLaunchError.self) {
            _ = try await launcher.launch(agent)
        }
    }

    @Test("Throws when there is no launch spec")
    func noSpec() async {
        let launcher = AgentLauncher(transportProvider: FakeTransportProvider())
        let agent = DiscoveredAgent(id: "x", name: "X", source: .registry, method: .npx, readiness: .ready, launchSpec: nil)
        await #expect(throws: AgentLaunchError.self) {
            _ = try await launcher.launch(agent)
        }
    }

    @Test("Readiness reports readiness correctly")
    func readinessFlags() {
        #expect(AgentReadiness.ready.isReady)
        #expect(!AgentReadiness.needsRunner("npx").isReady)
        #expect(!AgentReadiness.unavailable("x").isReady)
    }

    @Test("DiscoveredAgent is identifiable")
    func identifiable() {
        #expect(readyAgent().id == "x")
    }
}
