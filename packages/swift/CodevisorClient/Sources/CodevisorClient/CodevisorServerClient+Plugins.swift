import Foundation

/// One pane a plugin contributes (mirrors `PluginPaneDescriptor` in
/// packages/api). `path` is the plugin-server path the pane's webview loads
/// through the proxy.
public struct ServerPluginPaneDescriptor: Codable, Equatable, Identifiable, Sendable {
    /// Pane type, unique within the plugin (e.g. "diff").
    public var type: String
    public var title: String
    public var path: String
    /// Optional SF Symbol for pane chrome; clients fall back to a generic
    /// puzzle-piece symbol.
    public var icon: String?

    public var id: String { type }

    public init(type: String, title: String, path: String, icon: String? = nil) {
        self.type = type
        self.title = title
        self.path = path
        self.icon = icon
    }
}

/// A plugin installed on a machine (mirrors `PluginSummary` in packages/api).
public struct ServerPluginSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String?
    public var panes: [ServerPluginPaneDescriptor]
    /// managed | linked
    public var source: String
    public var path: String
    /// stopped | starting | running | stopping | failed
    public var state: String
    /// How many workspace pane records currently point at this plugin —
    /// route-layer enrichment, so uninstall confirmations can warn that
    /// those panes will close. Absent from older servers.
    public var openPaneCount: Int?

    public init(
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        panes: [ServerPluginPaneDescriptor] = [],
        source: String,
        path: String,
        state: String,
        openPaneCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.panes = panes
        self.source = source
        self.path = path
        self.state = state
        self.openPaneCount = openPaneCount
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
    public var panes: [ServerPluginPaneDescriptor]
    public var installCommand: String?
    public var runCommand: String
    public var alreadyInstalled: Bool

    public init(
        id: String,
        name: String,
        version: String,
        description: String? = nil,
        panes: [ServerPluginPaneDescriptor] = [],
        installCommand: String? = nil,
        runCommand: String,
        alreadyInstalled: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.panes = panes
        self.installCommand = installCommand
        self.runCommand = runCommand
        self.alreadyInstalled = alreadyInstalled
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

extension CodevisorServerClient {
    private struct PluginListResponse: Decodable {
        var plugins: [ServerPluginSummary]
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

    public func listPlugins() async throws -> [ServerPluginSummary] {
        let response: PluginListResponse = try await get("/v1/plugins")
        return response.plugins
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
