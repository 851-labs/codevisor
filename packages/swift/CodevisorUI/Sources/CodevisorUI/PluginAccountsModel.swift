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
  @ObservationIgnored private let webSignIn: any WebSignInPresenting
  @ObservationIgnored private var accountsBeforeSignIn: [ServerPluginAccount]?
  @ObservationIgnored private var signInBrowser: PluginSignInBrowser?

  public init(
    server: ServerMcpServer,
    client: any CodevisorServerClienting,
    spec: ServerPluginAccountSpec? = nil,
    webSignIn: any WebSignInPresenting = PluginWebSignIn()
  ) {
    self.spec = spec
    serverId = server.id
    catalogId = server.catalogId
    receivesWebhooks = !(server.capabilities?.ingress ?? []).isEmpty
    self.client = client
    self.webSignIn = webSignIn
  }

  public func load() async {
    if spec == nil, let catalogId {
      spec = await report { try await read { try await client.pluginCatalogEntry(id: catalogId).accounts } } ?? nil
    }
    await reload()
  }

  public func reload() async {
    guard spec != nil else { return }
    let listed = await report { try await read { try await client.listPluginAccounts(serverId: serverId) } }
    guard let loaded = listed else { return }

    accounts = loaded
    closeSignInIfAccountsChanged()
    ingress = await ingressURLs(for: loaded)
    hasLoaded = true
  }

  public func makeGuide() -> PluginAccountGuideModel? {
    guard let spec, spec.guide != nil else { return nil }
    return PluginAccountGuideModel(spec: spec, serverId: serverId, catalogId: catalogId, client: client)
  }

  public func takeFirstRunGuide() -> PluginAccountGuideModel? {
    guard hasLoaded, accounts.isEmpty, !Self.offeredGuides.contains(serverId) else { return nil }
    guard let guide = makeGuide() else { return nil }

    Self.offeredGuides.insert(serverId)
    return guide
  }

  public func takeFirstRunEditing() -> PluginAccountEditing? {
    guard hasLoaded, accounts.isEmpty, !Self.offeredGuides.contains(serverId) else { return nil }
    guard let spec, spec.guide == nil, !spec.signsInDirectly else { return nil }

    Self.offeredGuides.insert(serverId)
    return PluginAccountEditing(newAccountFor: spec)
  }

  private static var offeredGuides: Set<String> = []

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
    accountId: String? = nil,
    browser opened: PluginSignInBrowser? = nil
  ) async {
    let browser =
      opened ?? PluginSignInBrowser(client: client, pluginName: spec?.providerName, presenter: webSignIn)
    let request = ServerPluginAccountOAuthRequest(values: values, label: label, accountId: accountId)
    let started = await perform {
      try await client.startPluginAccountOAuth(serverId: serverId, request: request, ticket: browser.ticket)
    }
    guard let started else {
      await browser.abandon()
      return
    }

    accountsBeforeSignIn = hasLoaded ? accounts : nil
    signInBrowser = browser
    let callback = await browser.finish(at: started.authorizationUrl)
    accountsBeforeSignIn = nil
    signInBrowser = nil
    guard let callback, Self.carriesAuthorization(callback) else {
      await reload()
      return
    }
    let accountsBefore = accounts
    let completed: Void? = await perform { try await client.completePluginAccountOAuth(callbackURL: callback) }
    if completed == nil, accounts != accountsBefore { errorMessage = nil }
  }

  private static func carriesAuthorization(_ callback: URL) -> Bool {
    callback.host()?.lowercased() == BrowserSignIn.pluginOAuthHost
  }

  public func remove(_ account: ServerPluginAccount) async {
    _ = await perform { try await client.removePluginAccount(serverId: serverId, accountId: account.id) }
  }

  private func closeSignInIfAccountsChanged() {
    guard let accountsBeforeSignIn, accounts != accountsBeforeSignIn else { return }
    signInBrowser?.close()
  }

  private func perform<Result>(_ operation: () async throws -> Result) async -> Result? {
    isWorking = true
    defer { isWorking = false }
    let result = await report(operation)
    let failure = errorMessage
    await reload()
    if result == nil { errorMessage = failure }
    return result
  }

  private func report<Result>(_ operation: () async throws -> Result) async -> Result? {
    do {
      let result = try await operation()
      errorMessage = nil
      return result
    } catch  where isTaskCancellation(error) {
      return nil
    } catch {
      pluginSignInLog.error("Plugin account step failed: \(error, privacy: .public)")
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return nil
    }
  }

  private func read<Result>(_ operation: () async throws -> Result) async throws -> Result {
    try await ServerConnectionLoss.retryingInterruptions(sleep: { try await Task.sleep(for: $0) }, operation)
  }

  private func ingressURLs(for accounts: [ServerPluginAccount]) async -> [String: [ServerPluginIngressURL]] {
    guard receivesWebhooks, spec?.guide == nil else { return [:] }
    var urls: [String: [ServerPluginIngressURL]] = [:]
    for account in accounts {
      urls[account.id] = try? await client.pluginAccountIngress(serverId: serverId, accountId: account.id)
    }
    return urls
  }
}
