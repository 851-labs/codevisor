import CodevisorCore
import Foundation
import Observation

public struct PluginConnectHost {
  public var install:
    @MainActor (_ values: [String: ServerConfigFieldValue], _ authType: String?) async throws -> ServerMcpServer
  public var didInstall: @MainActor (ServerMcpServer) -> Void
  public var signIn: (@MainActor (ServerMcpServer, PluginSignInBrowser) async -> Void)?
  public var signInFailed: @MainActor (String) -> Void

  public init(
    install: @escaping @MainActor ([String: ServerConfigFieldValue], String?) async throws -> ServerMcpServer,
    didInstall: @escaping @MainActor (ServerMcpServer) -> Void,
    signIn: (@MainActor (ServerMcpServer, PluginSignInBrowser) async -> Void)?,
    signInFailed: @escaping @MainActor (String) -> Void
  ) {
    self.install = install
    self.didInstall = didInstall
    self.signIn = signIn
    self.signInFailed = signInFailed
  }
}

public enum PluginConnectSetup: Equatable, Sendable {
  case checking
  case install
  case serverSignIn(isOptional: Bool)
  case accountSignIn(title: String)
  case accountSetup(title: String)
}

@MainActor
@Observable
public final class PluginConnectModel {
  public enum Choice: Sendable {
    case finishSetup
    case skipSignIn
  }

  public let entry: ServerPluginCatalogEntry
  public let installed: ServerMcpServer?
  public var draft: ConfigFieldDraft
  public private(set) var isWorking = false
  public var errorMessage: String?

  private var serverSignIn: ServerPluginCatalogSignIn.OAuth?
  private var hasChecked = false

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let host: PluginConnectHost
  @ObservationIgnored private let webSignIn: any WebSignInPresenting

  public init(
    entry: ServerPluginCatalogEntry,
    installed: ServerMcpServer? = nil,
    client: any CodevisorServerClienting,
    host: PluginConnectHost,
    webSignIn: any WebSignInPresenting = PluginWebSignIn()
  ) {
    self.entry = entry
    self.installed = installed
    self.client = client
    self.host = host
    self.webSignIn = webSignIn
    draft = ConfigFieldDraft(fields: installed == nil ? entry.installFields : [])
  }

  public var isInstalled: Bool { installed != nil }

  public var setup: PluginConnectSetup {
    if let spec = entry.accounts {
      return spec.signsInDirectly ? .accountSignIn(title: spec.addTitle) : .accountSetup(title: spec.addTitle)
    }
    guard signsInToServerHere else { return .install }
    if installed != nil { return .serverSignIn(isOptional: false) }
    guard entry.transport == "http" else { return .install }
    guard hasChecked else { return .checking }

    switch serverSignIn {
    case .required: return .serverSignIn(isOptional: false)
    case .optional: return .serverSignIn(isOptional: true)
    case .some(.none), nil: return .install
    }
  }

  public var primaryTitle: String? {
    switch setup {
    case .checking: nil
    case .install: "Install"
    case .serverSignIn: "Sign in with \(entry.name)"
    case let .accountSignIn(title), let .accountSetup(title): title
    }
  }

  public var skipTitle: String? {
    setup == .serverSignIn(isOptional: true) ? "Use Without Signing In" : nil
  }

  public var signInNote: String? {
    guard !signsInToServerHere, entry.accounts == nil, installed == nil else { return nil }

    switch serverSignIn {
    case .required, .optional: return PluginSignInError.needsMac(plugin: entry.name).errorDescription
    case .some(.none), nil: return nil
    }
  }

  public var canContinue: Bool { draft.isComplete && !isWorking }

  public func load() async {
    guard installed == nil, entry.accounts == nil, entry.transport == "http", !hasChecked else { return }

    serverSignIn = try? await client.pluginCatalogSignIn(id: entry.id).oauth
    hasChecked = true
  }

  public func run(_ choice: Choice) async -> Bool {
    isWorking = true
    defer { isWorking = false }
    let browser = opensBrowser(for: choice) ? makeBrowser() : nil
    do {
      let server = try await installedServer(for: choice)
      errorMessage = nil
      host.didInstall(server)
      startSignIn(to: server, browser: browser, choice: choice)
      return true
    } catch {
      await browser?.abandon()
      errorMessage = ErrorReporter.userFacingMessage(for: error)
      return false
    }
  }

  private func installedServer(for choice: Choice) async throws -> ServerMcpServer {
    if let installed { return installed }
    return try await host.install(draft.submittedValues, authType(for: choice))
  }

  private func opensBrowser(for choice: Choice) -> Bool {
    guard choice == .finishSetup else { return false }

    switch setup {
    case .serverSignIn, .accountSignIn: return true
    case .checking, .install, .accountSetup: return false
    }
  }

  private func authType(for choice: Choice) -> String? {
    guard case .serverSignIn = setup else { return nil }
    return choice == .finishSetup ? "oauth" : "none"
  }

  private func makeBrowser() -> PluginSignInBrowser {
    PluginSignInBrowser(client: client, pluginName: signInName, presenter: webSignIn)
  }

  private var signsInToServerHere: Bool { host.signIn != nil }

  private var signInName: String {
    entry.accounts?.providerName ?? entry.name
  }

  private func startSignIn(to server: ServerMcpServer, browser: PluginSignInBrowser?, choice: Choice) {
    let needsServerSignIn = entry.accounts == nil && (server.awaitsAuthorization || installed != nil)
    let signsInToServer = needsServerSignIn && signsInToServerHere
    let detectedLate = choice == .finishSetup && signsInToServer
    guard let browser = browser ?? (detectedLate ? makeBrowser() : nil) else { return }

    Task { await signIn(to: server, browser: browser) }
  }

  private func signIn(to server: ServerMcpServer, browser: PluginSignInBrowser) async {
    guard let spec = entry.accounts else {
      await host.signIn?(server, browser)
      return
    }
    let accounts = PluginAccountsModel(server: server, client: client, spec: spec, webSignIn: webSignIn)
    await accounts.signIn(browser: browser)
    if let message = accounts.errorMessage { host.signInFailed(message) }
  }
}
