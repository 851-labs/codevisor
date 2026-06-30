import Foundation
import Testing
@testable import ACPAgents

@Suite("Registry models and client")
struct RegistryTests {
    @Test("Manifest and registry round-trip")
    func roundTrip() throws {
        let registry = AgentRegistry(version: "1.0.0", agents: [
            AgentManifest(
                id: "demo",
                name: "Demo Agent",
                version: "0.1.0",
                description: "A demo",
                distribution: AgentDistribution(
                    npx: NpxDistribution(package: "@demo/acp", args: ["--flag"], env: ["K": "V"]),
                    uvx: UvxDistribution(package: "demo-acp"),
                    binary: ["darwin-aarch64": BinaryDistribution(archive: "https://x.zip", cmd: "./demo", args: [])]
                ),
                repository: "https://github.com/demo",
                icon: "icon.svg"
            )
        ])
        let data = try JSONEncoder().encode(registry)
        let decoded = try JSONDecoder().decode(AgentRegistry.self, from: data)
        #expect(decoded == registry)
        #expect(decoded.agents.first?.id == "demo")
    }

    @Test("Decodes a registry JSON document")
    func decodesJSON() throws {
        let json = """
        {"version":"1.0.0","agents":[{"id":"a","name":"A","distribution":{"npx":{"package":"p"}}}]}
        """
        let registry = try JSONDecoder().decode(AgentRegistry.self, from: Data(json.utf8))
        #expect(registry.agents.count == 1)
        #expect(registry.agents[0].distribution.npx?.package == "p")
    }

    @Test("RegistryClient loads a remote registry")
    func loadsRemote() async throws {
        let json = Data(#"{"version":"1","agents":[{"id":"x","name":"X","distribution":{"npx":{"package":"p"}}}]}"#.utf8)
        let client = RegistryClient(fetcher: FakeDataFetcher(result: .success(json)))
        let registry = await client.load()
        #expect(registry.agents.map(\.id) == ["x"])
    }

    @Test("RegistryClient falls back on fetch failure")
    func fallbackOnFailure() async throws {
        let client = RegistryClient(
            fetcher: FakeDataFetcher(result: .failure(.boom)),
            fallbackProvider: { AgentRegistry(agents: [AgentManifest(id: "fb", name: "FB", distribution: AgentDistribution())]) }
        )
        let registry = await client.load()
        #expect(registry.agents.map(\.id) == ["fb"])
    }

    @Test("RegistryClient falls back on decode failure")
    func fallbackOnDecodeFailure() async throws {
        let client = RegistryClient(
            fetcher: FakeDataFetcher(result: .success(Data("not json".utf8))),
            fallbackProvider: { AgentRegistry(agents: []) }
        )
        let registry = await client.load()
        #expect(registry.agents.isEmpty)
    }

    @Test("Bundled registry decodes from the package resource")
    func bundledRegistry() {
        let registry = RegistryClient.bundledRegistry()
        #expect(registry.agents.isEmpty)
        #expect(registry.version != nil)
    }

    @Test("Default registry URL is the ACP CDN")
    func defaultURL() {
        #expect(RegistryClient.defaultRegistryURL.host == "cdn.agentclientprotocol.com")
    }
}
