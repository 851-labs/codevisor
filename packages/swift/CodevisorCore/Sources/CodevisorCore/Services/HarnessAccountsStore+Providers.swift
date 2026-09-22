import ACPKit
import Foundation

public extension HarnessAccountsStore {
  private func removeSharedOAuth(harnessId: String, profileId: String = "default", providerId: String) async throws {
    guard !machineId.isEmpty else { return }
    await sync.synchronize(machineId: machineId, namespaces: ["harness-shared-accounts"])
    let exists = sync.entries(namespace: "harness-shared-accounts").contains { entry in
      guard entry.deleted != true, entry.key.hasPrefix("provider:"), case .object(let row) = entry.value else {
        return false
      }
      return row["harnessId"] == .string(harnessId) && row["profileId"] == .string(profileId)
        && row["providerId"] == .string(providerId) && row["credential"] != nil
    }
    if exists {
      _ = try await shared(harnessId, .init(action: "logout", accountId: profileId, providerId: providerId))
    }
  }

  /// The namespaces a shared provider list depends on. Pulling the whole
  /// replica here made every account click wait on unrelated planes.
  static let sharedProviderNamespaces = ["harness-shared-accounts", HarnessSharedCredentials.namespace]

  func listOpenCodeAuthProviders(accountId: String) async throws -> [ServerOpenCodeAuthProvider] {
    guard isShared else { return try await client.listOpenCodeAuthProviders(accountId: accountId) }
    var catalog: [ServerOpenCodeAuthProvider] = []
    if !machineId.isEmpty {
      await sync.synchronize(machineId: machineId, namespaces: Self.sharedProviderNamespaces)
      catalog = try await shared("opencode", .init(action: "providers", accountId: accountId)).openCodeProviders ?? []
    } else if let host = await HarnessFleet.findSharedHost(harnessId: "opencode", environment: environment) {
      let remote = environment.machines.client(for: host.machineId)
      if let accounts = try? await remote.listHarnessAccounts(harnessId: "opencode"),
        let account = accounts.first(where: { $0.profileKind == "default" }),
        let providers = try? await remote.listOpenCodeAuthProviders(accountId: account.id)
      {
        catalog = providers
      }
    }
    let credentials = try HarnessSharedCredentials.opencode.credentials(
      from: content(credentialKey("opencode", accountId)))
    let ids = Set(catalog.map(\.id)).union(credentials.map(\.id)).union(["anthropic", "openai", "openrouter", "google"])
    return try ids.map { id in
      let credential = credentials.first { $0.id == id }
      if var provider = catalog.first(where: { $0.id == id }) {
        if provider.credentialType != "oauth" {
          provider.credentialType = credential == nil ? nil : (credential?.canReplaceKey == true ? "api" : "wellknown")
        }
        return provider
      }
      return try decoded(
        ServerOpenCodeAuthProvider.self,
        [
          "id": .string(id), "name": .string(HarnessSharedCredentials.providerName(id)),
          "methods": .array([
            .object(["id": .string("0"), "type": .string("api"), "label": .string("API Key"), "prompts": .array([])])
          ]),
          "credentialType": credential == nil ? .null : .string("api"),
        ])
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func startOpenCodeAuth(
    accountId: String, providerId: String, methodId: String, inputs: [String: String]?, apiKey: String?
  ) async throws -> ServerOpenCodeAuthFlow {
    guard isShared else {
      return try await client.startOpenCodeAuth(
        accountId: accountId, providerId: providerId, methodId: methodId, inputs: inputs, apiKey: apiKey)
    }
    guard let apiKey else {
      await sync.synchronize(machineId: machineId, namespaces: Self.sharedProviderNamespaces)
      guard
        let flow = try await shared(
          "opencode",
          .init(
            action: "login", accountId: accountId,
            methodId: methodId, providerId: providerId, inputs: inputs)
        ).openCodeFlow
      else { throw CodevisorServerClientError.invalidResponse }
      return flow
    }
    try await removeSharedOAuth(harnessId: "opencode", profileId: accountId, providerId: providerId)
    let key = try credentialKey("opencode", accountId)
    let updated = try HarnessSharedCredentials.opencode.replacingKey(
      in: content(key), providerId: providerId, key: apiKey)
    var object = try JSONDecoder().decode([String: JSONValue].self, from: Data(updated.utf8))
    if let inputs, case .object(var provider) = object[providerId] {
      provider["metadata"] = .object(inputs.mapValues(JSONValue.string))
      object[providerId] = .object(provider)
    }
    sync.set(
      namespace: Self.namespace, key: key,
      value: .string(String(decoding: try JSONEncoder().encode(object), as: UTF8.self)))
    return try decoded(
      ServerOpenCodeAuthFlow.self,
      [
        "id": .string(UUID().uuidString), "accountId": .string(accountId), "providerId": .string(providerId),
        "state": .string("complete"),
      ])
  }

  func removeOpenCodeAuthProvider(accountId: String, providerId: String) async throws {
    guard isShared else {
      return try await client.removeOpenCodeAuthProvider(accountId: accountId, providerId: providerId)
    }
    try await removeSharedOAuth(harnessId: "opencode", profileId: accountId, providerId: providerId)
    let key = try credentialKey("opencode", accountId)
    let updated = try HarnessSharedCredentials.opencode.removing(from: content(key), providerId: providerId) ?? "{}"
    sync.set(namespace: Self.namespace, key: key, value: .string(updated))
  }

  func openCodeAuthFlow(id: String) async throws -> ServerOpenCodeAuthFlow { try await client.openCodeAuthFlow(id: id) }
  func answerOpenCodeAuthFlow(id: String, code: String) async throws -> ServerOpenCodeAuthFlow {
    try await client.answerOpenCodeAuthFlow(id: id, code: code)
  }
  func cancelOpenCodeAuthFlow(id: String) async throws { try await client.cancelOpenCodeAuthFlow(id: id) }

  func listPiAuthProviders() async throws -> [ServerPiAuthProvider] {
    guard isShared else { return try await client.listPiAuthProviders() }
    var catalog: [ServerPiAuthProvider] = []
    if !machineId.isEmpty {
      catalog = try await shared("pi", .init(action: "providers")).piProviders ?? []
    } else if let host = await HarnessFleet.findSharedHost(harnessId: "pi", environment: environment),
      let providers = try? await environment.machines.client(for: host.machineId).listPiAuthProviders()
    {
      catalog = providers
    }
    let credentials = try HarnessSharedCredentials.pi.credentials(from: HarnessSharedCredentials.pi.content(in: sync))
    let ids = Set(catalog.map(\.id)).union(credentials.map(\.id)).union(["anthropic", "openai", "google", "openrouter"])
    return try ids.map { id in
      if var provider = catalog.first(where: { $0.id == id }) {
        if provider.credentialType != "oauth" {
          provider.credentialType = credentials.contains(where: { $0.id == id }) ? "api_key" : nil
        }
        return provider
      }
      return try decoded(
        ServerPiAuthProvider.self,
        [
          "id": .string(id), "name": .string(HarnessSharedCredentials.providerName(id)),
          "methods": .array([.string("api_key")]),
          "credentialType": credentials.contains(where: { $0.id == id }) ? .string("api_key") : .null,
        ])
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func startPiAuth(providerId: String, method: String) async throws -> ServerPiAuthFlow {
    guard isShared else { return try await client.startPiAuth(providerId: providerId, method: method) }
    guard method == "api_key" else {
      guard let flow = try await shared("pi", .init(action: "login", methodId: method, providerId: providerId)).piFlow
      else { throw CodevisorServerClientError.invalidResponse }
      return flow
    }
    return try decoded(
      ServerPiAuthFlow.self,
      [
        "id": .string("shared-api-key:\(providerId)"), "providerId": .string(providerId), "state": .string("waiting"),
        "prompt": .object([
          "id": .string("api_key"), "type": .string("input"), "message": .string("API Key"), "options": .array([]),
        ]),
      ])
  }

  func answerPiAuthFlow(id: String, value: String) async throws -> ServerPiAuthFlow {
    guard isShared, id.hasPrefix("shared-api-key:") else {
      return try await client.answerPiAuthFlow(id: id, value: value)
    }
    let providerId = String(id.dropFirst("shared-api-key:".count))
    try await removeSharedOAuth(harnessId: "pi", providerId: providerId)
    let source = HarnessSharedCredentials.pi
    let updated = try source.replacingKey(in: source.content(in: sync), providerId: providerId, key: value)
    sync.set(namespace: Self.namespace, key: source.sourceKey, value: .string(updated))
    return try decoded(
      ServerPiAuthFlow.self, ["id": .string(id), "providerId": .string(providerId), "state": .string("complete")])
  }

  func piAuthFlow(id: String) async throws -> ServerPiAuthFlow { try await client.piAuthFlow(id: id) }
  func cancelPiAuthFlow(id: String) async throws {
    if !id.hasPrefix("shared-api-key:") { try await client.cancelPiAuthFlow(id: id) }
  }
  func removePiAuthProvider(id: String) async throws {
    guard isShared else { return try await client.removePiAuthProvider(id: id) }
    try await removeSharedOAuth(harnessId: "pi", providerId: id)
    let source = HarnessSharedCredentials.pi
    sync.set(
      namespace: Self.namespace, key: source.sourceKey,
      value: .string(try source.removing(from: source.content(in: sync), providerId: id) ?? "{}"))
  }
}
