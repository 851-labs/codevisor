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
}

public struct ServerInfo: Decodable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var kind: String
  public var version: String
  public var platform: String
  public var bindHost: String
  public var features: [String]?
  /// The machine's Codevisor Cloud device id, when it is cloud-connected —
  /// lets clients match this machine to its cloud presence entry.
  public var cloudDeviceId: String?

  public init(
    id: String,
    name: String,
    kind: String,
    version: String,
    platform: String,
    bindHost: String,
    features: [String]? = nil,
    cloudDeviceId: String? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.version = version
    self.platform = platform
    self.bindHost = bindHost
    self.features = features
    self.cloudDeviceId = cloudDeviceId
  }
}

/// The machine's cloud registration, from `GET /v1/cloud`.
public struct ServerCloudRegistration: Decodable, Equatable, Sendable {
  public var connected: Bool
  public var deviceId: String?
  public var state: String?
  /// "app" when the desktop app provisioned this registration (it follows
  /// the app's account session); "external" when `codevisor auth login` or
  /// dev auto-provisioning did (the app never tears those down).
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

/// A device on a paired machine's tailnet, from `GET /v1/tailnet/peers`.
/// Sandboxed clients (iOS) can't enumerate tailnet peers themselves, so a
/// paired machine's server reports its view and the client probes the peers'
/// tokenless /v1/discovery manifests from its own side.
public struct ServerTailnetPeer: Decodable, Equatable, Sendable {
  public var hostName: String
  /// MagicDNS name with the trailing dot stripped; preferred over the IP
  /// because it survives IP reassignment.
  public var dnsName: String?
  public var ip: String?
  public var os: String?
  public var online: Bool

  public init(hostName: String, dnsName: String? = nil, ip: String? = nil, os: String? = nil, online: Bool) {
    self.hostName = hostName
    self.dnsName = dnsName
    self.ip = ip
    self.os = os
    self.online = online
  }

  /// The address a client should dial: MagicDNS name, else the tailnet IP.
  public var host: String? {
    dnsName ?? ip
  }
}

public struct ServerTailnetPeers: Decodable, Equatable, Sendable {
  /// False when Tailscale isn't installed or running on the machine.
  public var available: Bool
  public var peers: [ServerTailnetPeer]

  public init(available: Bool, peers: [ServerTailnetPeer]) {
    self.available = available
    self.peers = peers
  }
}

/// Which release feed a server update check follows. `alpha` sees alpha AND
/// stable releases (newest wins); `stable` sees stable only. Mirrors the
/// server's `ServerUpdateChannel`.
public enum ServerUpdateChannel: String, Equatable, Sendable {
  case stable
  case alpha
}

/// An app-hosted server's report of the host app's unattended update
/// session (Sparkle running headless because a remote client asked that
/// machine to update). Mirrors `UpdateInfo.lastApply` on the wire.
public struct ServerUpdateApplyState: Decodable, Equatable, Sendable {
  public var state: String
  public var message: String?
  public var targetVersion: String?
  public var at: String

  public init(state: String, message: String? = nil, targetVersion: String? = nil, at: String) {
    self.state = state
    self.message = message
    self.targetVersion = targetVersion
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
  /// CI build numbers, the one release marker that agrees across feeds:
  /// alpha manifests carry the full prerelease tag while installed
  /// runtimes report their base marketing version, so version strings
  /// cannot confirm that an update landed. Absent on older servers.
  public var currentBuildNumber: Int?
  public var latestBuildNumber: Int?
  /// Present on app-hosted servers while the host app is installing (or
  /// after it failed to install) a remotely requested update.
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

/// The server's restart drain (`/v1/restart/drain`): whether it is holding
/// new prompts while live turns finish so it can restart safely.
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

/// Response of `POST /v1/update/apply`.
public struct ServerUpdateApplied: Decodable, Equatable, Sendable {
  public var accepted: Bool
  public var targetVersion: String?
  /// The accepted release's CI build number. Clients confirm the restart
  /// against this instead of `targetVersion`: version strings differ
  /// between alpha manifests and installed runtimes, build numbers never
  /// do. Absent on older servers.
  public var targetBuildNumber: Int?
  /// When `accepted` is false, why the server declined — e.g. "busy" while
  /// chats are still running. Absent on older servers and on plain
  /// already-up-to-date responses.
  public var reason: String?
  /// True when the server accepted but is first waiting for live chats to
  /// finish (its restart drain); `updateInfo().lastApply` reports progress.
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

public struct ServerPairingToken: Decodable, Equatable, Sendable {
  public var token: String
  public var createdAt: String

  public init(
    token: String,
    createdAt: String
  ) {
    self.token = token
    self.createdAt = createdAt
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
    struct Body: Encodable {
      let serverUrl: String
      let sessionToken: String
    }
    struct Response: Decodable {
      let deviceId: String
    }
    let response: Response = try await send(
      "/v1/cloud/connect",
      method: "POST",
      body: Body(serverUrl: serverURL.absoluteString, sessionToken: sessionToken)
    )
    return response.deviceId
  }

  public func disconnectCloud() async throws {
    try await sendNoResponse("/v1/cloud/disconnect", method: "POST")
  }

  public func tailnetPeers() async throws -> ServerTailnetPeers {
    try await get("/v1/tailnet/peers")
  }

  /// `refresh` bypasses the server's update-check cache so a banner shown
  /// while the user is looking at a machine reflects the live release
  /// state; `channel` forwards the app's alpha-updates preference. Older
  /// servers ignore both query parameters.
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

  public func issuePairingToken() async throws -> ServerPairingToken {
    try await send("/v1/auth/pairing-token", method: "POST", body: Optional<EmptyBody>.none)
  }

  public func connectionToken() async throws -> ServerPairingToken {
    try await get("/v1/auth/connection-token")
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

  /// Starts (or, with `interrupt`, hurries) the server's restart drain and
  /// returns its current state; poll `restartDrainState()` until drained.
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

  /// Abandons a drain whose update is not happening after all, so held
  /// prompts dispatch again.
  public func cancelRestartDrain() async throws {
    try await sendNoResponse("/v1/restart/drain", method: "DELETE")
  }
}
