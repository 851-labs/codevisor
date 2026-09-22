import ACPKit
import Foundation

/// The account editor uses the same operations in shared and machine settings.
@MainActor public struct HarnessAccountsStore {
  let environment: AppEnvironment
  let machineId: String
  public let isShared: Bool

  public init(environment: AppEnvironment, machineId: String, isShared: Bool = false) {
    self.environment = environment
    self.machineId = machineId
    self.isShared = isShared
  }

  var client: any CodevisorServerClienting { environment.machines.client(for: machineId) }
  var sync: ConfigSync { environment.configSync }
  static let namespace = HarnessSharedCredentials.namespace
  /// Fleet accounts kept as server-side rows go over one RPC; fleet
  /// credentials (OpenCode, Pi) are assembled from the replica below.
  func usesSharedOAuth(_ harnessId: String) -> Bool {
    isShared && HarnessRegistry.descriptor(for: harnessId).usesFleetAccountRows
  }

  func shared(
    _ harnessId: String, _ request: ServerSharedHarnessAccountRequest
  ) async throws -> ServerSharedHarnessAccountResponse {
    _ = await environment.machines.cloudProvider?.prepareAccountSync(on: client, machineId: machineId)
    return try await client.sharedHarnessAccount(harnessId: harnessId, request: request)
  }

  struct Profile: Codable, Equatable {
    var id: String
    var label: String
  }
  struct Profiles: Codable {
    var profiles: [Profile] = []
    var activeProfileId = "default"
  }

  func profiles() throws -> Profiles {
    guard case .string(let content) = sync.value(namespace: Self.namespace, key: "profiles:opencode") else {
      return Profiles()
    }
    return try JSONDecoder().decode(Profiles.self, from: Data(content.utf8))
  }

  func save(_ profiles: Profiles) throws {
    let content = String(decoding: try JSONEncoder().encode(profiles), as: UTF8.self)
    sync.set(namespace: Self.namespace, key: "profiles:opencode", value: .string(content))
  }

  func credentialKey(_ harnessId: String, _ accountId: String = "default") throws -> String {
    guard let source = HarnessSharedCredentials(rawValue: harnessId) else {
      throw CodevisorServerClientError.invalidResponse
    }
    if harnessId == "opencode", accountId != "default" {
      guard try profiles().profiles.contains(where: { $0.id == accountId }) else {
        throw CodevisorServerClientError.invalidResponse
      }
      return "opencode-profile:\(accountId)"
    }
    return source.sourceKey
  }

  func content(_ key: String) -> String? {
    guard case .string(let content) = sync.value(namespace: Self.namespace, key: key) else { return nil }
    return content
  }

  func decoded<T: Decodable>(_ type: T.Type, _ fields: [String: JSONValue]) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(JSONValue.object(fields)))
  }

  public func listHarnessAccounts(harnessId: String) async throws -> [ServerHarnessAccount] {
    if usesSharedOAuth(harnessId) { return try await shared(harnessId, .init(action: "list")).accounts ?? [] }
    guard isShared else { return try await client.listHarnessAccounts(harnessId: harnessId) }
    if !machineId.isEmpty {
      await sync.synchronize(machineId: machineId, namespaces: ["harness-shared-accounts"])
    }
    let document = harnessId == "opencode" ? try profiles() : Profiles()
    let items =
      [Profile(id: "default", label: harnessId == "opencode" ? "Default Profile" : "OpenAI")]
      + document.profiles
    return try items.map { profile in
      let key = try credentialKey(harnessId, profile.id)
      let credentials = try HarnessSharedCredentials(rawValue: harnessId)?.credentials(from: content(key)) ?? []
      let hasOAuth = sync.entries(namespace: "harness-shared-accounts").contains { entry in
        guard entry.deleted != true, entry.key.hasPrefix("provider:"), case .object(let row) = entry.value else {
          return false
        }
        return row["harnessId"] == .string(harnessId) && row["profileId"] == .string(profile.id)
          && row["credential"] != nil
      }
      return try decoded(
        ServerHarnessAccount.self,
        [
          "id": .string(profile.id), "harnessId": .string(harnessId),
          "label": .string(profile.label), "profileKind": .string(profile.id == "default" ? "default" : "managed"),
          "authState": .string(credentials.isEmpty && !hasOAuth ? "unauthenticated" : "authenticated"),
          "authMethod": .string(hasOAuth ? "oauth" : "apiKey"),
          "isActive": .bool(document.activeProfileId == profile.id),
          "canLogin": .bool(true), "canLogout": .bool(!credentials.isEmpty || hasOAuth),
        ])
    }
  }

  public func createHarnessAccount(harnessId: String, label: String?) async throws -> ServerHarnessAccount {
    if usesSharedOAuth(harnessId) {
      guard let account = try await shared(harnessId, .init(action: "create", label: label)).account else {
        throw CodevisorServerClientError.invalidResponse
      }
      return account
    }
    guard isShared else { return try await client.createHarnessAccount(harnessId: harnessId, label: label) }
    guard harnessId == "opencode" else { throw CodevisorServerClientError.invalidResponse }
    var document = try profiles()
    let id = "shared-\(UUID().uuidString.lowercased())"
    document.profiles.append(Profile(id: id, label: label ?? "Profile \(document.profiles.count + 1)"))
    try save(document)
    sync.set(namespace: Self.namespace, key: "opencode-profile:\(id)", value: .string("{}"))
    guard let account = try await listHarnessAccounts(harnessId: harnessId).first(where: { $0.id == id }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    return account
  }

  public func renameHarnessAccount(
    harnessId: String, accountId: String, label: String
  ) async throws -> ServerHarnessAccount {
    if usesSharedOAuth(harnessId) {
      guard
        let account = try await shared(harnessId, .init(action: "rename", accountId: accountId, label: label)).account
      else { throw CodevisorServerClientError.invalidResponse }
      return account
    }
    guard isShared else {
      return try await client.renameHarnessAccount(harnessId: harnessId, accountId: accountId, label: label)
    }
    var document = try profiles()
    guard let index = document.profiles.firstIndex(where: { $0.id == accountId }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    document.profiles[index].label = label
    try save(document)
    guard let account = try await listHarnessAccounts(harnessId: harnessId).first(where: { $0.id == accountId }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    return account
  }

  public func removeHarnessAccount(harnessId: String, accountId: String) async throws {
    if usesSharedOAuth(harnessId) {
      _ = try await shared(harnessId, .init(action: "remove", accountId: accountId)); return
    }
    guard isShared else { return try await client.removeHarnessAccount(harnessId: harnessId, accountId: accountId) }
    var document = try profiles()
    guard document.profiles.contains(where: { $0.id == accountId }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    document.profiles.removeAll { $0.id == accountId }
    if document.activeProfileId == accountId { document.activeProfileId = "default" }
    try save(document)
    sync.remove(namespace: Self.namespace, key: "opencode-profile:\(accountId)")
  }

  public func activateHarnessAccount(harnessId: String, accountId: String) async throws -> [ServerHarnessAccount] {
    if usesSharedOAuth(harnessId) {
      return try await shared(harnessId, .init(action: "activate", accountId: accountId)).accounts ?? []
    }
    guard isShared else { return try await client.activateHarnessAccount(harnessId: harnessId, accountId: accountId) }
    var document = try profiles()
    guard accountId == "default" || document.profiles.contains(where: { $0.id == accountId }) else {
      throw CodevisorServerClientError.invalidResponse
    }
    document.activeProfileId = accountId
    try save(document)
    return try await listHarnessAccounts(harnessId: harnessId)
  }

  public func sharedHarness(id: String, name: String) throws -> ServerHarness {
    let auth = try decoded(
      ServerHarnessAuth.self,
      [
        "state": .string("authenticated"), "accounts": .array([]),
        "supportsMultipleAccounts": .bool(HarnessRegistry.descriptor(for: id).supportsMultipleAccounts),
        "loginMethods": .array([
          .object(["id": .string("apiKey"), "name": .string("API Key"), "kind": .string("apiKey")]),
          .object([
            "id": .string(id == "codex" ? "chatgpt" : "oauth"),
            "name": .string(id == "claude-code" ? "Claude" : "ChatGPT"),
            "kind": .string(id == "claude-code" ? "pasteCode" : "browser"),
          ]),
        ]),
      ])
    return ServerHarness(
      id: id, name: name, symbolName: "terminal", source: "builtin", launchKind: "cli",
      enabled: true, readiness: .init(state: "ready"), auth: auth)
  }
}
