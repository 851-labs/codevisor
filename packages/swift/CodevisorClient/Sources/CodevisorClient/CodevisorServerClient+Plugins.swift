import Foundation

public struct ServerPluginPaneDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var type: String
  public var title: String
  public var path: String
  public var iconPath: String?

  public var id: String { type }

  public init(type: String, title: String, path: String, iconPath: String? = nil) {
    self.type = type
    self.title = title
    self.path = path
    self.iconPath = iconPath
  }
}

public struct ServerPluginToolDescriptor: Codable, Hashable, Identifiable, Sendable {
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

public struct ServerPluginSummary: Codable, Equatable, Identifiable, Sendable {
  public var ageRating: Int?
  public var consentKey: String?
  public var sourceRepo: String?
  public var enabled: Bool?
  public var canRestore: Bool?
  public var id: String
  public var name: String
  public var version: String
  public var description: String?
  public var iconPath: String?
  public var panes: [ServerPluginPaneDescriptor]
  public var tools: [ServerPluginToolDescriptor]?
  public var source: String
  public var path: String
  public var state: String
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

public struct ServerPluginUpdateReview: Codable, Equatable, Sendable {
  public var ageRating: Int?
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

public struct ServerPluginRemoteDiscovery: Codable, Equatable, Sendable {
  public var ageRating: Int?
  public var consentKey: String?
  public var sourceRepo: String?
  public var id: String
  public var name: String
  public var version: String
  public var description: String?
  public var iconPath: String?
  public var panes: [ServerPluginPaneDescriptor]
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

public struct ServerPluginRegistryEntry: Codable, Hashable, Identifiable, Sendable {
  public var ageRating: Int?
  public var id: String
  public var name: String
  public var version: String
  public var description: String?
  public var iconPath: String?
  public var panes: [ServerPluginPaneDescriptor]
  public var tools: [ServerPluginToolDescriptor]?
  public var repo: String
  public var ownerAvatarUrl: String?
  public var stars: Int
  public var pushedAt: String
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

public struct ServerPluginRegistryIndex: Codable, Equatable, Sendable {
  public var generatedAt: String?
  public var entries: [ServerPluginRegistryEntry]

  public init(generatedAt: String? = nil, entries: [ServerPluginRegistryEntry]) {
    self.generatedAt = generatedAt
    self.entries = entries
  }
}

public struct ServerPluginPaneTokenResponse: Codable, Equatable, Sendable {
  public var token: String
  public var path: String
  public var url: String?
  public var expiresAt: String

  public init(token: String, path: String, url: String? = nil, expiresAt: String) {
    self.token = token
    self.path = path
    self.url = url
    self.expiresAt = expiresAt
  }
}

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

  public func unlinkPlugin(pluginId: String) async throws -> [ServerPluginSummary] {
    let response: PluginListResponse = try await send(
      "/v1/plugins/\(pathComponent(pluginId))/link",
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
