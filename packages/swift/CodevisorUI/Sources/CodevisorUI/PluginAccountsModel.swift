import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginAccountsModel {
  public private(set) var spec: ServerPluginAccountSpec?
  public private(set) var accounts: [ServerPluginAccount] = []
  public private(set) var ingress: [String: [ServerPluginIngressURL]] = [:]
  public private(set) var hasLoaded = false
  public private(set) var isWorking = false
  public var errorMessage: String?

  @ObservationIgnored public let serverId: String
  @ObservationIgnored private let catalogId: String?
  @ObservationIgnored private let receivesWebhooks: Bool
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let webSignIn = PluginWebSignIn()

  public init(
    server: ServerMcpServer,
    client: any CodevisorServerClienting,
    spec: ServerPluginAccountSpec? = nil
  ) {
    self.spec = spec
    serverId = server.id
    catalogId = server.catalogId
    receivesWebhooks = !(server.capabilities?.ingress ?? []).isEmpty
    self.client = client
  }

  public func load() async {
    if spec == nil, let catalogId {
      spec = await report { try await client.pluginCatalogEntry(id: catalogId).accounts } ?? nil
    }
    await reload()
  }

  public func reload() async {
    guard spec != nil else { return }
    guard let loaded = await report({ try await client.listPluginAccounts(serverId: serverId) }) else { return }

    accounts = loaded
    ingress = await ingressURLs(for: loaded)
    hasLoaded = true
  }

  public func submit(_ editing: PluginAccountEditing) async -> Bool {
    if editing.oauthProvider != nil {
      await signIn(values: editing.draft.submittedValues, label: editing.trimmedLabel, accountId: editing.accountId)
      return true
    }
    let draft = ServerPluginAccountDraft(label: editing.trimmedLabel, values: editing.draft.submittedValues)
    let saved = await perform {
      try await client.savePluginAccount(serverId: serverId, accountId: editing.accountId, draft: draft)
    }
    return saved != nil
  }

  public func signIn(
    values: [String: ServerConfigFieldValue] = [:],
    label: String? = nil,
    accountId: String? = nil
  ) async {
    let request = ServerPluginAccountOAuthRequest(values: values, label: label, accountId: accountId)
    guard let start = await perform({ try await client.startPluginAccountOAuth(serverId: serverId, request: request) })
    else { return }
    guard let url = URL(string: start.authorizationUrl) else { return }

    await webSignIn.run(url, callbackScheme: start.callbackScheme)
    await reload()
  }

  public func remove(_ account: ServerPluginAccount) async {
    _ = await perform { try await client.removePluginAccount(serverId: serverId, accountId: account.id) }
  }

  private func perform<Result>(_ operation: () async throws -> Result) async -> Result? {
    isWorking = true
    defer { isWorking = false }
    let result = await report(operation)
    await reload()
    return result
  }

  private func report<Result>(_ operation: () async throws -> Result) async -> Result? {
    do {
      let result = try await operation()
      errorMessage = nil
      return result
    } catch {
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return nil
    }
  }

  private func ingressURLs(for accounts: [ServerPluginAccount]) async -> [String: [ServerPluginIngressURL]] {
    guard receivesWebhooks else { return [:] }
    var urls: [String: [ServerPluginIngressURL]] = [:]
    for account in accounts {
      urls[account.id] = try? await client.pluginAccountIngress(serverId: serverId, accountId: account.id)
    }
    return urls
  }
}
