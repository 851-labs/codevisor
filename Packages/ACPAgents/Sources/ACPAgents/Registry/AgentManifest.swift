import Foundation

/// A distribution that launches an agent via `npx` (npm package runner).
public struct NpxDistribution: Sendable, Codable, Equatable {
    public var package: String
    public var args: [String]?
    public var env: [String: String]?

    public init(package: String, args: [String]? = nil, env: [String: String]? = nil) {
        self.package = package
        self.args = args
        self.env = env
    }
}

/// A distribution that launches an agent via `uvx` (Python package runner).
public struct UvxDistribution: Sendable, Codable, Equatable {
    public var package: String
    public var args: [String]?
    public var env: [String: String]?

    public init(package: String, args: [String]? = nil, env: [String: String]? = nil) {
        self.package = package
        self.args = args
        self.env = env
    }
}

/// A distribution that launches an agent from a prebuilt binary for a platform.
public struct BinaryDistribution: Sendable, Codable, Equatable {
    public var archive: String?
    public var cmd: String
    public var args: [String]?

    public init(archive: String? = nil, cmd: String, args: [String]? = nil) {
        self.archive = archive
        self.cmd = cmd
        self.args = args
    }
}

/// The set of ways an agent may be launched. At least one should be present.
public struct AgentDistribution: Sendable, Codable, Equatable {
    public var npx: NpxDistribution?
    public var uvx: UvxDistribution?
    public var binary: [String: BinaryDistribution]?

    public init(
        npx: NpxDistribution? = nil,
        uvx: UvxDistribution? = nil,
        binary: [String: BinaryDistribution]? = nil
    ) {
        self.npx = npx
        self.uvx = uvx
        self.binary = binary
    }
}

/// A registry entry describing an ACP-compatible agent and how to run it.
public struct AgentManifest: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var version: String?
    public var description: String?
    public var distribution: AgentDistribution
    public var repository: String?
    public var icon: String?

    public init(
        id: String,
        name: String,
        version: String? = nil,
        description: String? = nil,
        distribution: AgentDistribution,
        repository: String? = nil,
        icon: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.distribution = distribution
        self.repository = repository
        self.icon = icon
    }
}

/// The top-level registry document.
public struct AgentRegistry: Sendable, Codable, Equatable {
    public var version: String?
    public var agents: [AgentManifest]

    public init(version: String? = nil, agents: [AgentManifest]) {
        self.version = version
        self.agents = agents
    }
}
