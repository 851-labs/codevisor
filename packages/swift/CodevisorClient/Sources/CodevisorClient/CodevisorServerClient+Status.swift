import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerHealth: Decodable, Equatable, Sendable {
  public var ok: Bool
  public var version: String
  public var database: String
  public var bootId: String? = nil
  public var processId: Int? = nil
  public var appOwned: Bool? = nil
  public var buildNumber: Int? = nil
  public var sourceRevision: String? = nil
  public var serviceManaged: Bool? = nil
  public var migration: ServerMigrationProgress?

  public init(
    ok: Bool,
    version: String,
    database: String,
    bootId: String? = nil,
    processId: Int? = nil,
    appOwned: Bool? = nil,
    buildNumber: Int? = nil,
    sourceRevision: String? = nil,
    serviceManaged: Bool? = nil,
    migration: ServerMigrationProgress? = nil
  ) {
    self.ok = ok
    self.version = version
    self.database = database
    self.bootId = bootId
    self.processId = processId
    self.appOwned = appOwned
    self.buildNumber = buildNumber
    self.sourceRevision = sourceRevision
    self.serviceManaged = serviceManaged
    self.migration = migration
  }
}

public struct ServerMigrationProgress: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var completed: Int
  public var total: Int
  public var error: String?

  public init(id: String, name: String, completed: Int, total: Int, error: String? = nil) {
    self.id = id
    self.name = name
    self.completed = completed
    self.total = total
    self.error = error
  }

  public var fractionCompleted: Double? {
    guard total > 0 else { return nil }
    return min(1, max(0, Double(completed) / Double(total)))
  }
}

public struct ServerInfo: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var kind: String
  public var version: String
  public var platform: String
  public var bindHost: String
  public var features: [String]?
  public var maxUploadBytes: Int?
  public var cloudDeviceId: String?

  public init(
    id: String,
    name: String,
    kind: String,
    version: String,
    platform: String,
    bindHost: String,
    features: [String]? = nil,
    maxUploadBytes: Int? = nil,
    cloudDeviceId: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.version = version
    self.platform = platform
    self.bindHost = bindHost
    self.features = features
    self.maxUploadBytes = maxUploadBytes
    self.cloudDeviceId = cloudDeviceId
  }
}

public struct ServerCloudRegistration: Decodable, Equatable, Sendable {
  public var connected: Bool
  public var deviceId: String?
  public var state: String?
  public var managedBy: String?

  public init(
    connected: Bool,
    deviceId: String? = nil,
    state: String? = nil,
    managedBy: String? = nil
  ) {
    self.connected = connected
    self.deviceId = deviceId
    self.state = state
    self.managedBy = managedBy
  }
}

public enum ServerUpdateChannel: String, Equatable, Sendable {
  case stable
  case alpha
}

public struct ServerUpdateApplyState: Decodable, Equatable, Sendable {
  public var progress: Double?
  public var state: String
  public var message: String?
  public var targetVersion: String?
  public var targetBuildNumber: Int?
  public var at: String

  public init(
    state: String,
    message: String? = nil,
    targetVersion: String? = nil,
    targetBuildNumber: Int? = nil,
    progress: Double? = nil,
    at: String
  ) {
    self.progress = progress
    self.state = state
    self.message = message
    self.targetVersion = targetVersion
    self.targetBuildNumber = targetBuildNumber
    self.at = at
  }
}

public struct ServerUpdateInfo: Decodable, Equatable, Sendable {
  public var currentVersion: String
  public var latestVersion: String
  public var updateAvailable: Bool
  public var channel: String
  public var checkedAt: String?
  public var migrationState: String
  public var currentBuildNumber: Int?
  public var latestBuildNumber: Int?
  public var lastApply: ServerUpdateApplyState?

  public init(
    currentVersion: String,
    latestVersion: String,
    updateAvailable: Bool,
    channel: String,
    checkedAt: String?,
    migrationState: String,
    currentBuildNumber: Int? = nil,
    latestBuildNumber: Int? = nil,
    lastApply: ServerUpdateApplyState? = nil
  ) {
    self.currentVersion = currentVersion
    self.latestVersion = latestVersion
    self.updateAvailable = updateAvailable
    self.channel = channel
    self.checkedAt = checkedAt
    self.migrationState = migrationState
    self.currentBuildNumber = currentBuildNumber
    self.latestBuildNumber = latestBuildNumber
    self.lastApply = lastApply
  }
}

public struct ServerRestartDrainState: Decodable, Equatable, Sendable {
  public var state: String
  public var remaining: Int
  public var startedAt: String?
  public var deadlineAt: String?

  public init(state: String, remaining: Int, startedAt: String? = nil, deadlineAt: String? = nil) {
    self.state = state
    self.remaining = remaining
    self.startedAt = startedAt
    self.deadlineAt = deadlineAt
  }

  public var isDrained: Bool { state == "drained" }
}

public struct ServerUpdateApplied: Decodable, Equatable, Sendable {
  public var accepted: Bool
  public var targetVersion: String?
  public var targetBuildNumber: Int?
  public var reason: String?
  public var draining: Bool?

  public init(
    accepted: Bool,
    targetVersion: String?,
    targetBuildNumber: Int? = nil,
    reason: String? = nil,
    draining: Bool? = nil
  ) {
    self.accepted = accepted
    self.targetVersion = targetVersion
    self.targetBuildNumber = targetBuildNumber
    self.reason = reason
    self.draining = draining
  }
}

extension CodevisorServerClient {
  public func health() async throws -> ServerHealth {
    try await get("/v1/health")
  }

  public func info() async throws -> ServerInfo {
    try await get("/v1/info")
  }

  public func cloudRegistration() async throws -> ServerCloudRegistration {
    try await get("/v1/cloud")
  }

  public func connectCloud(serverURL: URL, sessionToken: String) async throws -> String {
    try await connectCloud(body: CloudConnectBody(serverUrl: serverURL.absoluteString, sessionToken: sessionToken))
  }

  public func connectCloud(
    serverURL: URL,
    sessionToken: String,
    managedBy: String,
    machineName: String?
  ) async throws -> String {
    try await connectCloud(
      body: CloudConnectBody(
        serverUrl: serverURL.absoluteString,
        sessionToken: sessionToken,
        managedBy: managedBy,
        machineName: machineName
      )
    )
  }

  private struct CloudConnectBody: Encodable {
    var serverUrl: String
    var sessionToken: String
    var managedBy: String?
    var machineName: String?
  }

  private func connectCloud(body: CloudConnectBody) async throws -> String {
    struct Response: Decodable {
      let deviceId: String
    }
    let response: Response = try await send("/v1/cloud/connect", method: "POST", body: body)
    return response.deviceId
  }

  public func disconnectCloud() async throws {
    try await sendNoResponse("/v1/cloud/disconnect", method: "POST")
  }

  public func updateInfo(
    refresh: Bool = false,
    channel: ServerUpdateChannel = .stable
  ) async throws -> ServerUpdateInfo {
    var query: [String] = []
    if refresh { query.append("refresh=1") }
    if channel != .stable { query.append("channel=\(channel.rawValue)") }
    let suffix = query.isEmpty ? "" : "?\(query.joined(separator: "&"))"
    return try await get("/v1/update\(suffix)")
  }

  public func capabilities(cwd: String) async throws -> ServerCapabilities {
    try await capabilities(cwd: cwd, harnessId: nil, configSelections: [:])
  }

  public func capabilities(cwd: String, harnessId: String) async throws -> ServerCapabilities {
    try await capabilities(cwd: cwd, harnessId: Optional(harnessId), configSelections: [:])
  }

  public func capabilities(
    cwd: String,
    harnessId: String,
    configSelections: [String: String]
  ) async throws -> ServerCapabilities {
    try await capabilities(
      cwd: cwd,
      harnessId: Optional(harnessId),
      configSelections: configSelections
    )
  }

  private func capabilities(
    cwd: String,
    harnessId: String?,
    configSelections: [String: String]
  ) async throws -> ServerCapabilities {
    var components = URLComponents()
    components.path = "/v1/capabilities"
    components.queryItems = [URLQueryItem(name: "cwd", value: cwd)]
    if let harnessId {
      components.queryItems?.append(URLQueryItem(name: "harnessId", value: harnessId))
    }
    components.queryItems?.append(
      contentsOf: configSelections.sorted { $0.key < $1.key }.map { configId, value in
        URLQueryItem(name: "config.\(configId)", value: value)
      }
    )
    guard let path = components.string else {
      throw CodevisorServerClientError.invalidURL("capabilities")
    }
    return try await get(path)
  }

  public func requestShutdown() async throws {
    try await sendNoResponse("/v1/shutdown", method: "POST")
  }

  public func applyServerUpdate(
    channel: ServerUpdateChannel = .stable
  ) async throws -> ServerUpdateApplied {
    let suffix = channel == .stable ? "" : "?channel=\(channel.rawValue)"
    return try await send("/v1/update/apply\(suffix)", method: "POST", body: Optional<EmptyBody>.none)
  }

  private struct RestartDrainBody: Encodable {
    var interrupt: Bool
  }

  public func beginRestartDrain(interrupt: Bool = false) async throws -> ServerRestartDrainState {
    try await send(
      "/v1/restart/drain",
      method: "POST",
      body: RestartDrainBody(interrupt: interrupt)
    )
  }

  public func restartDrainState() async throws -> ServerRestartDrainState {
    try await get("/v1/restart/drain")
  }

  public func cancelRestartDrain() async throws {
    try await sendNoResponse("/v1/restart/drain", method: "DELETE")
  }
}
