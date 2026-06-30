import Foundation

/// Fetches raw data for a URL. Abstracted to allow testing without networking.
public protocol DataFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

/// A `DataFetching` backed by `URLSession`.
public struct URLSessionDataFetcher: DataFetching {
    private let session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }
    public func data(from url: URL) async throws -> Data {
        try await session.data(from: url).0
    }
}

/// Loads the ACP agent registry, falling back to a bundled snapshot when the
/// network is unavailable.
public struct RegistryClient: Sendable {
    private let fetcher: any DataFetching
    private let registryURL: URL
    private let fallbackProvider: @Sendable () -> AgentRegistry

    public static let defaultRegistryURL = URL(
        string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json"
    )!

    public init(
        fetcher: any DataFetching = URLSessionDataFetcher(),
        registryURL: URL = RegistryClient.defaultRegistryURL,
        fallbackProvider: @escaping @Sendable () -> AgentRegistry = RegistryClient.bundledRegistry
    ) {
        self.fetcher = fetcher
        self.registryURL = registryURL
        self.fallbackProvider = fallbackProvider
    }

    /// Loads the registry, decoding the remote document or returning the
    /// bundled fallback on any failure.
    public func load() async -> AgentRegistry {
        do {
            let data = try await fetcher.data(from: registryURL)
            return try JSONDecoder().decode(AgentRegistry.self, from: data)
        } catch {
            return fallbackProvider()
        }
    }

    /// The registry snapshot bundled with the package.
    public static func bundledRegistry() -> AgentRegistry {
        guard
            let url = Bundle.module.url(forResource: "registry-fallback", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let registry = try? JSONDecoder().decode(AgentRegistry.self, from: data)
        else {
            return AgentRegistry(agents: [])
        }
        return registry
    }
}
