import Foundation

extension CodevisorServerClient {
  private struct AccountsResponse: Decodable {
    var accounts: [ServerPluginAccount]
  }

  private struct IngressResponse: Decodable {
    var ingress: [ServerPluginIngressURL]
  }

  private struct SubscriptionsResponse: Decodable {
    var subscriptions: [ServerPluginEventSubscription]
  }

  public func pluginCatalogEntry(id: String) async throws -> ServerPluginCatalogEntry {
    try await get("/v1/plugins/catalog/\(catalogPathComponent(id))")
  }

  public func listPluginAccounts(serverId: String) async throws -> [ServerPluginAccount] {
    let response: AccountsResponse = try await get(pluginAccountsPath(serverId))
    return response.accounts
  }

  public func savePluginAccount(
    serverId: String,
    accountId: String?,
    draft: ServerPluginAccountDraft
  ) async throws -> ServerPluginAccount {
    guard let accountId else {
      return try await send(pluginAccountsPath(serverId), method: "POST", body: draft)
    }
    return try await send(pluginAccountPath(serverId, accountId), method: "PUT", body: draft)
  }

  public func removePluginAccount(serverId: String, accountId: String) async throws {
    try await sendNoResponse(pluginAccountPath(serverId, accountId), method: "DELETE")
  }

  public func startPluginAccountOAuth(
    serverId: String,
    request: ServerPluginAccountOAuthRequest
  ) async throws -> ServerPluginAccountOAuthStart {
    try await send("\(pluginAccountsPath(serverId))/oauth/start", method: "POST", body: request)
  }

  public func pluginAccountIngress(serverId: String, accountId: String) async throws -> [ServerPluginIngressURL] {
    let response: IngressResponse = try await get("\(pluginAccountPath(serverId, accountId))/ingress")
    return response.ingress
  }

  public func listPluginEventSubscriptions() async throws -> [ServerPluginEventSubscription] {
    let response: SubscriptionsResponse = try await get("/v1/plugins/events/subscriptions")
    return response.subscriptions
  }

  public func removePluginEventSubscription(id: String) async throws {
    try await sendNoResponse("/v1/plugins/events/subscriptions/\(pathComponent(id))", method: "DELETE")
  }

  private func pluginAccountsPath(_ serverId: String) -> String {
    "/v1/plugins/\(pathComponent(serverId))/accounts"
  }

  private func pluginAccountPath(_ serverId: String, _ accountId: String) -> String {
    "\(pluginAccountsPath(serverId))/\(pathComponent(accountId))"
  }
}
