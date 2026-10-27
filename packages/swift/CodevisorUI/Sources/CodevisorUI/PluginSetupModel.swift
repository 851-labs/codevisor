import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class PluginSetupModel {
  public let request: ServerPluginSetupRequest
  public private(set) var entry: ServerPluginCatalogEntry?
  public private(set) var server: ServerMcpServer?
  public private(set) var accounts: PluginAccountsModel?
  public private(set) var hasChecked = false
  public private(set) var isWorking = false
  public var errorMessage: String?
  public var installing: ServerPluginCatalogEntry?
  public var addingAccount: PluginAccountEditing?

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let webSignIn = PluginWebSignIn()

  public init(request: ServerPluginSetupRequest, client: any CodevisorServerClienting) {
    self.request = request
    self.client = client
  }

  public var step: PluginSetupStep {
    guard hasChecked else { return .checking }
    guard let server else { return request.catalogId == nil ? .unavailable : .install }

    switch auth {
    case .fields, .oauth2: return (accounts?.accounts.isEmpty ?? true) ? .signIn : .ready
    case .mcpOAuth: return server.connectionState == "connected" ? .ready : .signIn
    case .none: return .ready
    }
  }

  public var actionTitle: String? {
    switch step {
    case .install: "Install"
    case .signIn: signInTitle
    case .checking, .ready, .unavailable: nil
    }
  }

  public func refresh() async {
    await loadEntry()
    guard let servers = await report({ try await client.listMcpServers() }) else { return }

    server = servers.first(where: matchesRequest)
    await refreshAccounts()
    hasChecked = true
  }

  public func performPrimaryAction() async {
    switch step {
    case .install: installing = entry
    case .signIn: await beginSignIn()
    case .checking, .ready, .unavailable: return
    }
  }

  public func install(values: [String: ServerConfigFieldValue]) async throws {
    guard let catalogId = request.catalogId else { return }

    _ = try await client.installCatalogPlugin(id: catalogId, values: values)
    await refresh()
  }

  private var auth: ServerPluginSetupRequest.Auth {
    if let spec = entry?.accounts { return spec.oauth == nil ? .fields : .oauth2 }
    if server?.authType == "oauth" { return .mcpOAuth }
    return entry == nil ? request.auth : .none
  }

  private var signInTitle: String {
    switch auth {
    case .oauth2: entry?.accounts?.addTitle ?? "Sign In"
    case .fields: "Add Account"
    case .mcpOAuth, .none: "Sign In"
    }
  }

  private func matchesRequest(_ server: ServerMcpServer) -> Bool {
    if let serverId = request.serverId, server.id == serverId { return true }
    guard let catalogId = request.catalogId else { return false }
    return server.catalogId == catalogId
  }

  private func loadEntry() async {
    guard entry == nil, let catalogId = request.catalogId else { return }
    entry = await report { try await client.pluginCatalogEntry(id: catalogId) }
  }

  private func refreshAccounts() async {
    guard let server, entry?.accounts != nil else {
      accounts = nil
      return
    }
    if accounts?.serverId != server.id {
      accounts = PluginAccountsModel(server: server, client: client, spec: entry?.accounts)
    }
    await accounts?.reload()
  }

  private func beginSignIn() async {
    if auth == .mcpOAuth {
      await signInToServer()
      return
    }
    guard let accounts, let spec = accounts.spec else { return }
    guard spec.signsInDirectly else {
      addingAccount = PluginAccountEditing(newAccountFor: spec)
      return
    }
    await working { await accounts.signIn() }
  }

  private func signInToServer() async {
    guard let server else { return }
    guard let start = await report({ try await client.startMcpOAuth(id: server.id) }),
      let url = URL(string: start.authorizationUrl)
    else { return }

    await working { await webSignIn.run(url) }
  }

  private func working(_ operation: () async -> Void) async {
    isWorking = true
    defer { isWorking = false }
    await operation()
    await refresh()
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
}
