import Foundation
import ACPKit

/// Errors raised while launching an agent.
public enum AgentLaunchError: Error, Equatable, Sendable {
    case notLaunchable(String)
}

/// Creates a started `Transport` for a process specification. Abstracted so the
/// launcher can be tested without spawning subprocesses.
public protocol TransportProviding: Sendable {
    func makeTransport(for spec: ProcessSpec) throws -> any Transport
}

/// A `TransportProviding` that starts a real `StdioTransport`.
public struct StdioTransportProvider: TransportProviding {
    public init() {}
    public func makeTransport(for spec: ProcessSpec) throws -> any Transport {
        let transport = StdioTransport(spec: spec)
        try transport.start()
        return transport
    }
}

/// Launches a discovered agent and returns a connected, started ACP client.
public struct AgentLauncher: Sendable {
    private let transportProvider: any TransportProviding

    public init(transportProvider: any TransportProviding = StdioTransportProvider()) {
        self.transportProvider = transportProvider
    }

    /// Launches the agent, optionally setting a client cwd by overriding the
    /// spec's working directory, and returns a started `ACPClient`.
    public func launch(
        _ agent: DiscoveredAgent,
        workingDirectory: URL? = nil,
        delegate: (any ACPClientDelegate)? = nil
    ) async throws -> ACPClient {
        guard agent.readiness.isReady, var spec = agent.launchSpec else {
            throw AgentLaunchError.notLaunchable(agent.name)
        }
        if let workingDirectory {
            spec.currentDirectoryURL = workingDirectory
        }
        let transport = try transportProvider.makeTransport(for: spec)
        let client = ACPClient(transport: transport, delegate: delegate)
        await client.start()
        return client
    }
}
