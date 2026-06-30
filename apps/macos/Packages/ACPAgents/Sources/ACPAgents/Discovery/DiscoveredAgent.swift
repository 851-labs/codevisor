import Foundation
import ACPKit

/// Where a discovered agent came from.
public enum AgentSource: Sendable, Equatable {
    /// Described by a registry manifest.
    case registry
    /// Found by scanning `PATH` for an ACP binary.
    case path
}

/// How a distribution will be launched.
public enum LaunchMethod: String, Sendable, Equatable {
    case npx
    case uvx
    case binary
    case executable
}

/// Whether an agent is ready to launch, and if not, why.
public enum AgentReadiness: Sendable, Equatable {
    case ready
    /// A runner (e.g. `npx`) is required but was not found on `PATH`.
    case needsRunner(String)
    /// The agent cannot currently be launched (e.g. binary not installed).
    case unavailable(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// A short human-readable reason a harness isn't ready, if any.
    public var detail: String? {
        switch self {
        case .ready: return nil
        case let .needsRunner(runner): return "Requires \(runner)"
        case let .unavailable(reason): return reason
        }
    }
}

/// An ACP agent discovered on the local machine.
public struct DiscoveredAgent: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var source: AgentSource
    public var method: LaunchMethod
    public var readiness: AgentReadiness
    public var launchSpec: ProcessSpec?
    public var symbolName: String

    public init(
        id: String,
        name: String,
        source: AgentSource,
        method: LaunchMethod,
        readiness: AgentReadiness,
        launchSpec: ProcessSpec? = nil,
        symbolName: String = "cpu"
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.method = method
        self.readiness = readiness
        self.launchSpec = launchSpec
        self.symbolName = symbolName
    }
}
