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
  public private(set) var loadFailed = false
  public private(set) var isWorking = false
  public var errorMessage: String?
  public var connecting: PluginConnectTarget?
  public var addingAccount: PluginAccountEditing?
  public var guiding: PluginAccountGuideModel?

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let signInRoute: @MainActor () -> PluginSignInRoute
  @ObservationIgnored private let webSignIn: any WebSignInPresenting
  @ObservationIgnored private var signingIn: PluginSignInBrowser?
  @ObservationIgnored private var awaitsAccountSetup = false

  public init(
    request: ServerPluginSetupRequest,
    client: any CodevisorServerClienting,
    signInRoute: @escaping @MainActor () -> PluginSignInRoute = { .chatMachine },
    webSignIn: any WebSignInPresenting = PluginWebSignIn()
  ) {
    self.request = request
    self.client = client
    self.signInRoute = signInRoute
    self.webSignIn = webSignIn
  }

  public var step: PluginSetupStep {
    guard hasChecked else { return .checking }
    guard !loadFailed else { return .failed }
    guard let server else { return request.catalogId == nil ? .unavailable : .install }

    switch auth {
    case .fields, .oauth2: return (accounts?.accounts.isEmpty ?? true) ? .signIn : .ready
    case .mcpOAuth: return server.connectionState == "connected" ? .ready : .signIn
    case .none: return .ready
    }
  }

  public var canAct: Bool {
    switch step {
    case .install, .signIn, .failed: true
    case .checking, .ready, .unavailable: false
    }
  }

  private var signsInToServerHere: Bool { signInClient != nil }

  private var signInClient: (any CodevisorServerClienting)? {
    switch signInRoute() {
    case .chatMachine: client
    case let .localMac(local): local
    case .unavailable: nil
    }
  }

  public func refresh() async {
    await loadEntry()
    guard let servers = await report({ try await client.listMcpServers() }) else {
      loadFailed = true
      hasChecked = true
      return
    }

    loadFailed = false
    server = servers.first(where: matchesRequest)
    await refreshAccounts()
    hasChecked = true
    if step == .ready { closeSignIn() }
  }

  public func performPrimaryAction() async {
    switch step {
    case .install: beginInstall()
    case .signIn: await beginConnect()
    case .failed: await refresh()
    case .checking, .ready, .unavailable: return
    }
  }

  public func didInstall(_ server: ServerMcpServer) {
    self.server = server
    awaitsAccountSetup = entry?.accounts.map { !$0.signsInDirectly } ?? false
  }

  public func connectSheetDismissed() async {
    await refresh()
    guard awaitsAccountSetup else { return }

    awaitsAccountSetup = false
    if step == .signIn { await beginSignIn() }
  }

  public func connectHost(
    install: @escaping @MainActor ([String: ServerConfigFieldValue], String?) async throws -> ServerMcpServer
  ) -> PluginConnectHost {
    let signInClient = signInClient
    var signIn: (@MainActor (ServerMcpServer, PluginSignInBrowser) async -> Void)?
    if signInClient != nil {
      signIn = { [weak self] server, browser in await self?.signIn(to: server, browser: browser) }
    }
    return PluginConnectHost(
      install: install,
      didInstall: { [weak self] in self?.didInstall($0) },
      signIn: signIn,
      signInFailed: { [weak self] in self?.errorMessage = $0 },
      signInClient: signInClient
    )
  }

  public func signIn(to server: ServerMcpServer, browser: PluginSignInBrowser) async {
    guard let start = await report({ try await self.startSignIn(to: server, ticket: browser.ticket) }) else {
      await browser.abandon()
      return
    }

    signingIn = browser
    await working { _ = await browser.finish(at: start.authorizationUrl) }
    signingIn = nil
  }

  private var auth: ServerPluginSetupRequest.Auth {
    if let spec = entry?.accounts { return spec.oauth == nil ? .fields : .oauth2 }
    if server?.authType == "oauth" { return .mcpOAuth }
    return entry == nil ? request.auth : .none
  }

  private func beginInstall() {
    guard let entry else { return }
    connecting = PluginConnectTarget(entry: entry, installed: nil)
  }

  private func beginConnect() async {
    guard signsInFromConnectSheet, let entry, let server else {
      await beginSignIn()
      return
    }
    connecting = PluginConnectTarget(entry: entry, installed: server)
  }

  private var signsInFromConnectSheet: Bool {
    auth != .mcpOAuth || signsInToServerHere
  }

  private func closeSignIn() {
    webSignIn.cancel()
    signingIn?.close()
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
      accounts = PluginAccountsModel(server: server, client: client, spec: entry?.accounts, webSignIn: webSignIn)
    }
    await accounts?.reload()
  }

  private func beginSignIn() async {
    if auth == .mcpOAuth {
      await signInToServer()
      return
    }
    guard let accounts, let spec = accounts.spec else { return }
    if let guide = accounts.makeGuide() {
      guiding = guide
      return
    }
    guard spec.signsInDirectly else {
      addingAccount = PluginAccountEditing(newAccountFor: spec)
      return
    }
    await working { await accounts.signIn() }
  }

  private func signInToServer() async {
    guard let server else { return }
    guard let signInClient else {
      _ = await report { try await self.startSignIn(to: server, ticket: nil) }
      return
    }

    await signIn(
      to: server, browser: PluginSignInBrowser(client: signInClient, pluginName: server.name, presenter: webSignIn))
  }

  private func startSignIn(to server: ServerMcpServer, ticket: String?) async throws -> ServerMcpOAuthStart {
    try await ServerConnectionLoss.retryingInterruptions(sleep: { try await Task.sleep(for: $0) }) {
      try await startSignInOnce(to: server, ticket: ticket)
    }
  }

  private func startSignInOnce(to server: ServerMcpServer, ticket: String?) async throws -> ServerMcpOAuthStart {
    switch signInRoute() {
    case .chatMachine:
      return try await client.startMcpOAuth(id: server.id, ticket: ticket)
    case let .localMac(local):
      guard let copy = try await local.listMcpServers().first(where: { $0.isSamePlugin(as: server) }) else {
        throw PluginSignInError.notOnThisMac(plugin: server.name)
      }
      return try await local.startMcpOAuth(id: copy.id, ticket: ticket)
    case .unavailable:
      throw PluginSignInError.needsMac(plugin: server.name)
    }
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
    } catch  where isTaskCancellation(error) {
      return nil
    } catch {
      pluginSignInLog.error("Plugin setup step failed: \(error, privacy: .public)")
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return nil
    }
  }
}
