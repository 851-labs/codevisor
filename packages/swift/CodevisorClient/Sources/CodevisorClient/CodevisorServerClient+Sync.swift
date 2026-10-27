import ACPKit
import Foundation

public struct ServerSyncTimestamp: Codable, Equatable, Sendable {
  public var wallMs: Int
  public var counter: Int
  public var deviceId: String

  public init(wallMs: Int, counter: Int, deviceId: String) {
    self.wallMs = wallMs
    self.counter = counter
    self.deviceId = deviceId
  }

  public var date: Date { Date(timeIntervalSince1970: Double(wallMs) / 1000) }
}

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

public struct ServerSyncDocument: Codable, Equatable, Sendable {
  public var namespace: String
  public var entries: [ServerSyncEntry]

  public init(namespace: String, entries: [ServerSyncEntry]) {
    self.namespace = namespace
    self.entries = entries
  }
}

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

  public func reconcileHarnessesSync() async throws -> ServerHarnessSyncStatus {
    try await send(
      "/v1/sync/harnesses/reconcile",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }

  public func reconcileCredentialsSync() async throws -> JSONValue {
    try await send(
      "/v1/sync/credentials/reconcile",
      method: "POST",
      body: Optional<EmptyBody>.none
    )
  }
}

public struct ServerHarnessSyncBlocked: Codable, Equatable, Sendable {
  public var id: String
  public var reason: String

  public init(id: String, reason: String) {
    self.id = id
    self.reason = reason
  }
}

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
