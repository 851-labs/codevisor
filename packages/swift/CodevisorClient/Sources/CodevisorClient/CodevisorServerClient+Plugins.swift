import Foundation

/// One pane a plugin contributes (mirrors `PluginPaneDescriptor` in
/// packages/api). `path` is the plugin-server path the pane's webview loads
/// through the proxy.
public struct ServerPluginPaneDescriptor: Codable, Hashable, Identifiable, Sendable {
    /// Pane type, unique within the plugin (e.g. "diff").
    public var type: String
    public var title: String
    public var path: String
    /// Optional absolute path on the plugin server to pane artwork. When
    /// absent, clients inherit the plugin-level artwork.
    public var iconPath: String?

    public var id: String { type }

    public init(type: String, title: String, path: String, iconPath: String? = nil) {
        self.type = type
        self.title = title
        self.path = path
        self.iconPath = iconPath
    }
}

/// One agent tool a plugin contributes (mirrors `PluginToolDescriptor` in
/// packages/api). The server POSTs JSON arguments to `path` on the plugin's
/// server when an agent invokes the tool. The descriptor's opaque
/// `inputSchema` (a JSON Schema for the arguments) is not decoded
/// client-side — consent and settings surfaces only need name + description.
public struct ServerPluginToolDescriptor: Codable, Hashable, Identifiable, Sendable {
    /// Tool name, unique within the plugin (lowercase letters, digits,
    /// underscores).
    public var name: String
    public var description: String
    public var path: String

    public var id: String { name }

    public init(name: String, description: String, path: String) {
        self.name = name
        self.description = description
        self.path = path
    }
}

/// A plugin installed on a machine (mirrors `PluginSummary` in packages/api).
public struct ServerPluginSummary: Codable, Equatable, Identifiable, Sendable {
    /// Absent on older servers, where installed plugins were always enabled.
    public var enabled: Bool?
    /// Whether the server retains a verified pre-update backup.
    public var canRestore: Bool?
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var iconPath: String?
    public var panes: [ServerPluginPaneDescriptor]
    /// Agent tools the plugin declares; absent from older servers and from
    /// plugins that declare none.
    public var tools: [ServerPluginToolDescriptor]?
    /// managed | linked
    public var source: String
    public var path: String
    /// stopped | starting | running | stopping | failed
    public var state: String
    /// How many workspace pane records currently point at this plugin —
    /// route-layer enrichment, so uninstall confirmations can warn that
    /// those panes will close. Absent from older servers.
    public var openPaneCount: Int?

    public var isEnabled: Bool { enabled ?? true }

    public init(
        id: String,
        name: String,
        version: String,
        enabled: Bool? = nil,
        canRestore: Bool? = nil,
        description: String? = nil,
        iconPath: String? = nil,
        panes: [ServerPluginPaneDescriptor] = [],
        tools: [ServerPluginToolDescriptor]? = nil,
        source: String,
        path: String,
        state: String,
        openPaneCount: Int? = nil
    ) {
        self.enabled = enabled
        self.canRestore = canRestore
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.iconPath = iconPath
        self.panes = panes
        self.tools = tools
        self.source = source
        self.path = path
        self.state = state
        self.openPaneCount = openPaneCount
    }
}

/// One executable a plugin expects Codevisor to find before setup or launch.
public struct ServerPluginExecutableRequirement: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var installHint: String?
    public var helpUrl: String?

    public var id: String { name }

    public init(name: String, installHint: String? = nil, helpUrl: String? = nil) {
        self.name = name
        self.installHint = installHint
        self.helpUrl = helpUrl
    }
}

public struct ServerPluginRequirements: Codable, Equatable, Sendable {
    public var executables: [ServerPluginExecutableRequirement]?

    public init(executables: [ServerPluginExecutableRequirement]? = nil) {
        self.executables = executables
    }
}

/// Exhaustive registry-update state for one installed plugin.
public enum ServerPluginUpdateState: String, Codable, Equatable, Sendable {
    case current
    case available
    case pinned
    case incompatible
    case sourceUnknown
    case checkFailed
}

public struct ServerPluginUpdateStatus: Codable, Equatable, Identifiable, Sendable {
    public var pluginId: String
    public var installedVersion: String
    public var state: ServerPluginUpdateState
    public var checkedAt: String
    public var registryVersion: String?
    public var reason: String?

    public var id: String { pluginId }

    public init(
        pluginId: String,
        installedVersion: String,
        state: ServerPluginUpdateState,
        checkedAt: String,
        registryVersion: String? = nil,
        reason: String? = nil
    ) {
        self.pluginId = pluginId
        self.installedVersion = installedVersion
        self.state = state
        self.checkedAt = checkedAt
        self.registryVersion = registryVersion
        self.reason = reason
    }
}

/// Commands and capabilities on one side of a prepared update.
public struct ServerPluginUpdateReview: Codable, Equatable, Sendable {
    public var version: String
    public var setupCommands: [String]
    public var runCommand: String
    public var panes: [ServerPluginPaneDescriptor]
    public var tools: [ServerPluginToolDescriptor]?
    public var requirements: ServerPluginRequirements?

    public init(
        version: String,
        setupCommands: [String],
        runCommand: String,
        panes: [ServerPluginPaneDescriptor],
        tools: [ServerPluginToolDescriptor]? = nil,
        requirements: ServerPluginRequirements? = nil
    ) {
        self.version = version
        self.setupCommands = setupCommands
        self.runCommand = runCommand
        self.panes = panes
        self.tools = tools
        self.requirements = requirements
    }
}

public struct ServerPluginNamedChanges: Codable, Equatable, Sendable {
    public var added: [String]
    public var removed: [String]
    public var changed: [String]

    public init(added: [String], removed: [String], changed: [String]) {
        self.added = added
        self.removed = removed
        self.changed = changed
    }
}

/// A short-lived update prepared from exact, staged source bytes.
public struct ServerPluginUpdatePlan: Codable, Equatable, Identifiable, Sendable {
    public var planId: String
    public var pluginId: String
    public var name: String
    public var resolvedCommit: String
    public var expiresAt: String
    public var current: ServerPluginUpdateReview
    public var candidate: ServerPluginUpdateReview
    public var paneChanges: ServerPluginNamedChanges
    public var toolChanges: ServerPluginNamedChanges

    public var id: String { planId }

    public init(
        planId: String,
        pluginId: String,
        name: String,
        resolvedCommit: String,
        expiresAt: String,
        current: ServerPluginUpdateReview,
        candidate: ServerPluginUpdateReview,
        paneChanges: ServerPluginNamedChanges,
        toolChanges: ServerPluginNamedChanges
    ) {
        self.planId = planId
        self.pluginId = pluginId
        self.name = name
        self.resolvedCommit = resolvedCommit
        self.expiresAt = expiresAt
        self.current = current
        self.candidate = candidate
        self.paneChanges = paneChanges
        self.toolChanges = toolChanges
    }
}

/// What a staged plugin source offers (mirrors `DiscoverRemotePluginResult`
/// in packages/api). `installCommand`/`runCommand` are the VERBATIM manifest
/// command strings — the consent UI shows exactly these before anything runs
/// on the user's machine.
public struct ServerPluginRemoteDiscovery: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var iconPath: String?
    public var panes: [ServerPluginPaneDescriptor]
    /// Agent tools installation would add — shown on the consent sheet
    /// alongside the verbatim commands. Absent from older servers.
    public var tools: [ServerPluginToolDescriptor]?
    public var installCommand: String?
    public var runCommand: String
    public var alreadyInstalled: Bool

    public init(
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        iconPath: String? = nil,
        panes: [ServerPluginPaneDescriptor] = [],
        tools: [ServerPluginToolDescriptor]? = nil,
        installCommand: String? = nil,
        runCommand: String,
        alreadyInstalled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.iconPath = iconPath
        self.panes = panes
        self.tools = tools
        self.installCommand = installCommand
        self.runCommand = runCommand
        self.alreadyInstalled = alreadyInstalled
    }
}

/// One plugin in the public registry index (mirrors `PluginRegistryEntry` in
/// packages/api): manifest metadata renderable without running anything, plus
/// the GitHub facts (repo, stars, push time) that anchor it to a real owner.
public struct ServerPluginRegistryEntry: Codable, Hashable, Identifiable, Sendable {
    /// Owner-namespaced plugin id, lowercase `owner.name`.
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var iconPath: String?
    public var panes: [ServerPluginPaneDescriptor]
    public var tools: [ServerPluginToolDescriptor]?
    /// GitHub "owner/name" — the directory always shows the real repo owner.
    /// Feed this to the discover→consent→install flow as the plugin source.
    public var repo: String
    /// GitHub avatar of the repo owner — the only artwork renderable before
    /// install (`iconPath` is served by the plugin's own server, which isn't
    /// running yet). Absent from older indexes.
    public var ownerAvatarUrl: String?
    public var stars: Int
    public var pushedAt: String
    /// Curation groundwork: reserved for first-party verification of an
    /// entry. The indexer never sets it yet, so it is always absent today.
    public var verified: Bool?

    public init(
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        iconPath: String? = nil,
        panes: [ServerPluginPaneDescriptor] = [],
        tools: [ServerPluginToolDescriptor]? = nil,
        repo: String,
        ownerAvatarUrl: String? = nil,
        stars: Int,
        pushedAt: String,
        verified: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.iconPath = iconPath
        self.panes = panes
        self.tools = tools
        self.repo = repo
        self.ownerAvatarUrl = ownerAvatarUrl
        self.stars = stars
        self.pushedAt = pushedAt
        self.verified = verified
    }
}

/// The registry index served by `GET /v1/plugins/registry` (mirrors
/// `PluginRegistryIndex` in packages/api). The wire document also carries
/// `rejected` diagnostics for plugin authors; clients don't render them, so
/// decoding simply ignores that key.
public struct ServerPluginRegistryIndex: Codable, Equatable, Sendable {
    /// Null until the indexer's first poll completes — the cloud serves an
    /// honest empty index rather than a 404.
    public var generatedAt: String?
    public var entries: [ServerPluginRegistryEntry]

    public init(generatedAt: String? = nil, entries: [ServerPluginRegistryEntry]) {
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

/// A short-lived pane token plus the server-relative pane URL it unlocks
/// (mirrors `PluginPaneTokenResponse` in packages/api). Append `path` to the
/// machine's base URL and load it in a webview; the proxy exchanges the token
/// for a scoped cookie on the initial navigation.
public struct ServerPluginPaneTokenResponse: Codable, Equatable, Sendable {
    public var token: String
    public var path: String
    /// Absolute pane URL against the origin the caller reached the server on —
    /// for browser tooling. Native clients keep composing `path` against their
    /// machine base URL. Absent from older servers.
    public var url: String?
    public var expiresAt: String

    public init(token: String, path: String, url: String? = nil, expiresAt: String) {
        self.token = token
        self.path = path
        self.url = url
        self.expiresAt = expiresAt
    }
}

/// Plugin artwork normalized by the server to a bounded PNG, regardless of
/// whether the plugin supplied SVG, PNG, or WebP.
public struct ServerPluginIconAsset: Equatable, Sendable {
    public var data: Data
    public var contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }
}

extension CodevisorServerClient {
    private struct PluginListResponse: Decodable {
        var plugins: [ServerPluginSummary]
    }

    private struct PluginUpdatesResponse: Decodable {
        var updates: [ServerPluginUpdateStatus]
    }

    struct PluginPaneTokenBody: Encodable {
        var paneType: String
        var workspaceId: String?
        var cwd: String?
        var themeMode: String?
    }

    struct PluginSourceBody: Encodable {
        var source: String
    }

    struct PluginLinkBody: Encodable {
        var path: String
    }

    struct PluginUpdateApplyBody: Encodable {
        var planId: String
    }

    struct PluginSetEnabledBody: Encodable {
        var enabled: Bool
    }

    public func listPlugins() async throws -> [ServerPluginSummary] {
        let response: PluginListResponse = try await get("/v1/plugins")
        return response.plugins
    }

    public func listPluginUpdates() async throws -> [ServerPluginUpdateStatus] {
        let response: PluginUpdatesResponse = try await get("/v1/plugins/updates")
        return response.updates
    }

    public func preparePluginUpdate(pluginId: String) async throws -> ServerPluginUpdatePlan {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/update/prepare",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func applyPluginUpdate(pluginId: String, planId: String) async throws -> ServerPluginSummary {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/update/apply",
            method: "POST",
            body: PluginUpdateApplyBody(planId: planId)
        )
    }

    public func pluginIcon(pluginId: String, paneType: String? = nil) async throws -> ServerPluginIconAsset {
        let pluginPath = pathComponent(pluginId)
        let path: String
        if let paneType {
            path = "/v1/plugins/\(pluginPath)/panes/\(pathComponent(paneType))/icon"
        } else {
            path = "/v1/plugins/\(pluginPath)/icon"
        }
        let (data, response) = try await performRawResponse(
            path,
            method: "GET",
            body: nil,
            contentType: nil
        )
        guard
            response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
                .hasPrefix("image/png") == true
        else {
            throw CodevisorServerClientError.invalidResponse
        }
        return ServerPluginIconAsset(data: data, contentType: "image/png")
    }

    public func fetchPluginRegistry(query: String? = nil) async throws -> ServerPluginRegistryIndex {
        var path = "/v1/plugins/registry"
        if let query, !query.isEmpty {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            path += "?q=\(encoded)"
        }
        return try await get(path)
    }

    public func discoverRemotePlugin(source: String) async throws -> ServerPluginRemoteDiscovery {
        try await send(
            "/v1/plugins/discover-remote",
            method: "POST",
            body: PluginSourceBody(source: source)
        )
    }

    public func importRemotePlugin(source: String) async throws -> ServerPluginSummary {
        try await send(
            "/v1/plugins/import-remote",
            method: "POST",
            body: PluginSourceBody(source: source)
        )
    }

    public func linkPlugin(path: String) async throws -> ServerPluginSummary {
        try await send("/v1/plugins/link", method: "POST", body: PluginLinkBody(path: path))
    }

    public func removePlugin(pluginId: String) async throws -> [ServerPluginSummary] {
        let response: PluginListResponse = try await send(
            "/v1/plugins/\(pathComponent(pluginId))",
            method: "DELETE",
            body: Optional<EmptyBody>.none
        )
        return response.plugins
    }

    public func restartPlugin(pluginId: String) async throws -> ServerPluginSummary {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/restart",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func restorePlugin(pluginId: String) async throws -> ServerPluginSummary {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/restore",
            method: "POST",
            body: Optional<EmptyBody>.none
        )
    }

    public func setPluginEnabled(pluginId: String, enabled: Bool) async throws -> ServerPluginSummary {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/set-enabled",
            method: "POST",
            body: PluginSetEnabledBody(enabled: enabled)
        )
    }

    public func issuePluginPaneToken(
        pluginId: String,
        paneId: String,
        paneType: String,
        workspaceId: String?,
        cwd: String?,
        themeMode: String?
    ) async throws -> ServerPluginPaneTokenResponse {
        try await send(
            "/v1/plugins/\(pathComponent(pluginId))/panes/\(pathComponent(paneId))/token",
            method: "POST",
            body: PluginPaneTokenBody(
                paneType: paneType,
                workspaceId: workspaceId,
                cwd: cwd,
                themeMode: themeMode
            )
        )
    }
}
