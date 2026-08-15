import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerMcpServer: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: String?
    public var canEdit: Bool?
    public var canRemove: Bool?
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var headerNames: [String]?
    public var environmentNames: [String]?
    public var enabled: Bool
    public var authType: String
    public var oauthScope: String?
    public var connectionState: String
    public var toolCount: Int
    public var detail: String?
    public var createdAt: String
    public var updatedAt: String
}

public struct ServerBrowserUseConfiguration: Codable, Equatable, Sendable {
    public var preferredBrowser: String?
    public var chromeAvailable: Bool
    public var chromeConnected: Bool
    public var managedAvailable: Bool
    /// Nil on servers that predate the field; treat as supported. False on
    /// remote-kind servers, where no desktop user can complete the Chrome
    /// extension handshake and Browser Use always runs the managed browser.
    public var extensionFlowSupported: Bool?
    public var developmentExtensionPath: String?

    /// Whether clients should offer the Chrome/extension options at all.
    public var supportsExtensionFlow: Bool { extensionFlowSupported ?? true }

    public init(
        preferredBrowser: String? = nil,
        chromeAvailable: Bool,
        chromeConnected: Bool,
        managedAvailable: Bool,
        extensionFlowSupported: Bool? = nil,
        developmentExtensionPath: String? = nil
    ) {
        self.preferredBrowser = preferredBrowser
        self.chromeAvailable = chromeAvailable
        self.chromeConnected = chromeConnected
        self.managedAvailable = managedAvailable
        self.extensionFlowSupported = extensionFlowSupported
        self.developmentExtensionPath = developmentExtensionPath
    }
}

public struct ServerMcpTool: Codable, Equatable, Identifiable, Sendable {
    public var serverId: String
    public var serverName: String
    public var name: String
    public var title: String?
    public var description: String?
    public var id: String { "\(serverId)/\(name)" }
}

public struct ServerMcpOAuthStart: Codable, Equatable, Sendable {
    public var authorizationUrl: String
}

public struct ServerMcpAuthDetection: Codable, Equatable, Sendable {
    public var authType: String
    public var detail: String
    public var suggestedName: String? = nil
}

/// An MCP server registered directly in a harness's own config file. Secret
/// values never leave the server — only env/header names arrive for display.
public struct ServerNativeMcpServer: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    public var serverName: String
    /// "global" (user-level config) or "project" (committed file, read-only).
    public var scope: String
    public var configPath: String
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var envNames: [String]
    public var headerNames: [String]
    /// Present only when the harness has a real per-server enable flag.
    public var enabled: Bool?
    public var supportsDisable: Bool
    public var supportsRemove: Bool
    public var identity: String
    public var alreadyManaged: Bool

    public var id: String { "\(harnessId)|\(scope)|\(configPath)|\(serverName)" }

    public init(
        harnessId: String,
        harnessName: String,
        serverName: String,
        scope: String,
        configPath: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        envNames: [String] = [],
        headerNames: [String] = [],
        enabled: Bool? = nil,
        supportsDisable: Bool = false,
        supportsRemove: Bool = false,
        identity: String = "",
        alreadyManaged: Bool = false
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.serverName = serverName
        self.scope = scope
        self.configPath = configPath
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.envNames = envNames
        self.headerNames = headerNames
        self.enabled = enabled
        self.supportsDisable = supportsDisable
        self.supportsRemove = supportsRemove
        self.identity = identity
        self.alreadyManaged = alreadyManaged
    }
}

/// One importable server, coalesced across every harness it was found in.
public struct ServerNativeMcpImportCandidate: Codable, Equatable, Identifiable, Sendable {
    public var identity: String
    public var name: String
    public var transport: String
    public var url: String?
    public var command: String?
    public var args: [String]
    public var foundIn: [String]
    public var alreadyManaged: Bool

    public var id: String { identity }

    public init(
        identity: String,
        name: String,
        transport: String,
        url: String? = nil,
        command: String? = nil,
        args: [String] = [],
        foundIn: [String] = [],
        alreadyManaged: Bool = false
    ) {
        self.identity = identity
        self.name = name
        self.transport = transport
        self.url = url
        self.command = command
        self.args = args
        self.foundIn = foundIn
        self.alreadyManaged = alreadyManaged
    }
}

public struct ServerNativeMcpHarnessServers: Codable, Equatable, Identifiable, Sendable {
    public var harnessId: String
    public var harnessName: String
    /// SF Symbol from the harness catalog; nil from older servers.
    public var harnessSymbol: String?
    public var configPath: String
    public var exists: Bool
    /// Per-harness read/parse failure, surfaced instead of failing the scan.
    public var error: String?
    public var servers: [ServerNativeMcpServer]

    public var id: String { harnessId }

    public init(
        harnessId: String,
        harnessName: String,
        harnessSymbol: String? = nil,
        configPath: String,
        exists: Bool,
        error: String? = nil,
        servers: [ServerNativeMcpServer] = []
    ) {
        self.harnessId = harnessId
        self.harnessName = harnessName
        self.harnessSymbol = harnessSymbol
        self.configPath = configPath
        self.exists = exists
        self.error = error
        self.servers = servers
    }
}

public struct ServerNativeMcpScan: Codable, Equatable, Sendable {
    public var candidates: [ServerNativeMcpImportCandidate]
    public var harnesses: [ServerNativeMcpHarnessServers]

    public init(
        candidates: [ServerNativeMcpImportCandidate] = [],
        harnesses: [ServerNativeMcpHarnessServers] = []
    ) {
        self.candidates = candidates
        self.harnesses = harnesses
    }
}

public struct ServerNativeMcpImportOutcome: Codable, Equatable, Identifiable, Sendable {
    public var identity: String
    /// imported | skipped | failed
    public var status: String
    public var serverId: String?
    public var serverName: String?
    public var detail: String?
    public var warnings: [String]

    public var id: String { identity }

    public init(
        identity: String,
        status: String,
        serverId: String? = nil,
        serverName: String? = nil,
        detail: String? = nil,
        warnings: [String] = []
    ) {
        self.identity = identity
        self.status = status
        self.serverId = serverId
        self.serverName = serverName
        self.detail = detail
        self.warnings = warnings
    }
}

public struct ServerNativeMcpImportResult: Codable, Equatable, Sendable {
    public var outcomes: [ServerNativeMcpImportOutcome]
    /// Post-import rescan for wholesale state replacement.
    public var scan: ServerNativeMcpScan

    public init(outcomes: [ServerNativeMcpImportOutcome] = [], scan: ServerNativeMcpScan = .init()) {
        self.outcomes = outcomes
        self.scan = scan
    }
}

/// A server entry Codevisor removed from a harness config file, parked so
/// the removal can be undone.
public struct ServerNativeMcpRemoval: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var harnessId: String
    public var configPath: String
    public var serverName: String
    public var removedAt: String
    public var restoredAt: String?

    public init(
        id: String,
        harnessId: String,
        configPath: String,
        serverName: String,
        removedAt: String,
        restoredAt: String? = nil
    ) {
        self.id = id
        self.harnessId = harnessId
        self.configPath = configPath
        self.serverName = serverName
        self.removedAt = removedAt
        self.restoredAt = restoredAt
    }
}

public struct ServerRemoveNativeMcpResult: Codable, Equatable, Sendable {
    public var removal: ServerNativeMcpRemoval
    public var scan: ServerNativeMcpScan

    public init(removal: ServerNativeMcpRemoval, scan: ServerNativeMcpScan = .init()) {
        self.removal = removal
        self.scan = scan
    }
}
