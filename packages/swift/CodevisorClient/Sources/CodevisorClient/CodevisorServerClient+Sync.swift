import ACPKit
import Foundation

/// A hybrid logical clock stamp from the config plane (@codevisor/sync).
/// Total order: wallMs, then counter, then deviceId as the deterministic
/// tiebreak — every replica orders any two stamps identically.
public struct ServerSyncTimestamp: Codable, Equatable, Sendable {
  public var wallMs: Int
  public var counter: Int
  public var deviceId: String

  public init(wallMs: Int, counter: Int, deviceId: String) {
    self.wallMs = wallMs
    self.counter = counter
    self.deviceId = deviceId
  }
}

/// One replicated config key. Deletions are tombstones (`deleted: true`),
/// so a removal beats an older write on replicas that never saw the key.
public struct ServerSyncEntry: Codable, Equatable, Sendable {
  public var key: String
  public var value: JSONValue
  public var deleted: Bool?
  public var timestamp: ServerSyncTimestamp

  public init(key: String, value: JSONValue, deleted: Bool? = nil, timestamp: ServerSyncTimestamp) {
    self.key = key
    self.value = value
    self.deleted = deleted
    self.timestamp = timestamp
  }
}

/// One namespace's replica on one server.
public struct ServerSyncDocument: Codable, Equatable, Sendable {
  public var namespace: String
  public var entries: [ServerSyncEntry]

  public init(namespace: String, entries: [ServerSyncEntry]) {
    self.namespace = namespace
    self.entries = entries
  }
}

/// Outcome of one MCP-definitions reconcile pass on a machine.
public struct ServerMcpSyncStatus: Codable, Equatable, Sendable {
  public var published: [String]
  public var applied: [String]
  public var removed: [String]

  public init(published: [String], applied: [String], removed: [String]) {
    self.published = published
    self.applied = applied
    self.removed = removed
  }
}

public struct ServerSkillsSyncMissingBlob: Codable, Equatable, Sendable {
  public var directoryName: String
  public var hash: String

  public init(directoryName: String, hash: String) {
    self.directoryName = directoryName
    self.hash = hash
  }
}

/// Outcome of one skills reconcile pass on a machine — most importantly the
/// blobs it cannot apply until a client ferries them over.
public struct ServerSkillsSyncStatus: Codable, Equatable, Sendable {
  public var published: [String]
  public var applied: [String]
  public var removed: [String]
  public var missingBlobs: [ServerSkillsSyncMissingBlob]

  public init(
    published: [String],
    applied: [String],
    removed: [String],
    missingBlobs: [ServerSkillsSyncMissingBlob]
  ) {
    self.published = published
    self.applied = applied
    self.removed = removed
    self.missingBlobs = missingBlobs
  }
}

extension CodevisorServerClient {
  public func syncDocument(namespace: String) async throws -> ServerSyncDocument {
    try await get("/v1/sync/\(namespace)")
  }

  /// Merges entries into the machine's replica. The response is the merged
  /// document, so one round trip both pushes and pulls.
  public func mergeSyncDocument(
    namespace: String,
    entries: [ServerSyncEntry]
  ) async throws -> ServerSyncDocument {
    struct Body: Encodable {
      let entries: [ServerSyncEntry]
    }
    return try await send("/v1/sync/\(namespace)", method: "PUT", body: Body(entries: entries))
  }

  public func reconcileSkillsSync() async throws -> ServerSkillsSyncStatus {
    try await send("/v1/sync/skills/reconcile", method: "POST", body: Optional<EmptyBody>.none)
  }

  public func reconcileMcpsSync() async throws -> ServerMcpSyncStatus {
    try await send("/v1/sync/mcps/reconcile", method: "POST", body: Optional<EmptyBody>.none)
  }

  public func publishAccountsSync() async throws {
    try await sendNoResponse("/v1/sync/accounts/publish", method: "POST")
  }

  public func syncBlob(id: String) async throws -> Data {
    try await performRaw("/v1/sync/blobs/\(id)", method: "GET", body: nil, contentType: nil)
  }

  public func putSyncBlob(id: String, bytes: Data) async throws {
    _ = try await performRaw(
      "/v1/sync/blobs/\(id)",
      method: "PUT",
      body: bytes,
      contentType: "application/gzip"
    )
  }
}

/// Whether a machine participates in the config plane at all. Server-
/// enforced: while disabled, every sync surface on that machine refuses.
public struct ServerSyncParticipation: Codable, Equatable, Sendable {
  public var enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

extension CodevisorServerClient {
  public func syncParticipation() async throws -> ServerSyncParticipation {
    try await get("/v1/sync-participation")
  }

  public func setSyncParticipation(enabled: Bool) async throws -> ServerSyncParticipation {
    try await send(
      "/v1/sync-participation",
      method: "PUT",
      body: ServerSyncParticipation(enabled: enabled)
    )
  }
}

/// One machine blocked on itself: a sign-in required before an enable
/// applies, or no runnable install method. Retried on every pass.
public struct ServerHarnessSyncBlocked: Codable, Equatable, Sendable {
  public var id: String
  public var reason: String

  public init(id: String, reason: String) {
    self.id = id
    self.reason = reason
  }
}

/// POST /v1/sync/harnesses/reconcile: the harness plane's pass summary.
public struct ServerHarnessSyncStatus: Codable, Equatable, Sendable {
  public var published: [String]
  public var applied: [String]
  public var removed: [String]
  public var installing: [String]
  public var blocked: [ServerHarnessSyncBlocked]

  public init(
    published: [String],
    applied: [String],
    removed: [String],
    installing: [String],
    blocked: [ServerHarnessSyncBlocked]
  ) {
    self.published = published
    self.applied = applied
    self.removed = removed
    self.installing = installing
    self.blocked = blocked
  }
}

extension CodevisorServerClient {
  public func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus {
    try await send(
      "/v1/sync/harnesses/reconcile",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }
}

/// POST /v1/sync/plugins/reconcile: the plugin plane's pass summary.
public struct ServerPluginSyncStatus: Codable, Equatable, Sendable {
  public var published: [String]
  public var applied: [String]
  public var removed: [String]
  public var installed: [String]
  public var blocked: [ServerHarnessSyncBlocked]

  public init(
    published: [String],
    applied: [String],
    removed: [String],
    installed: [String],
    blocked: [ServerHarnessSyncBlocked]
  ) {
    self.published = published
    self.applied = applied
    self.removed = removed
    self.installed = installed
    self.blocked = blocked
  }
}

extension CodevisorServerClient {
  public func reconcilePluginsSync() async throws -> ServerPluginSyncStatus {
    try await send(
      "/v1/sync/plugins/reconcile",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }
}

extension CodevisorServerClient {
  public func reconcileCredentialsSync() async throws -> JSONValue {
    try await send(
      "/v1/sync/credentials/reconcile",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }
}
