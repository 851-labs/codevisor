import CodevisorCore
import CodevisorTestSupport
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct PluginConnectModelTests {
  @Test("The sheet's main button is whatever finishes setting that plugin up")
  func primaryButtonFollowsSetup() async throws {
    let transport = ConnectTransport()
    transport.respond("GET /v1/plugins/catalog/acme/sign-in", with: #"{"oauth":"required"}"#)
    transport.respond("GET /v1/plugins/catalog/shop/sign-in", with: #"{"oauth":"optional"}"#)
    transport.respond("GET /v1/plugins/catalog/notes/sign-in", with: #"{"oauth":"none"}"#)
    let host = ConnectHost()
    let make = { (entry: String) in
      PluginConnectModel(entry: try Self.entry(entry), client: Self.client(transport), host: host.host)
    }
    let required = try make(Self.remote(id: "acme", name: "Acme"))
    let optional = try make(Self.remote(id: "shop", name: "Shop"))
    let open = try make(Self.remote(id: "notes", name: "Notes"))
    let unreachable = try make(Self.remote(id: "offline", name: "Offline"))
    let linear = try make(Self.bundled(accounts: Self.linearAccounts))
    let slack = try make(Self.bundled(accounts: Self.slackAccounts))
    let bundled = try make(Self.bundled(accounts: nil))
    let models = [required, optional, open, unreachable, linear, slack, bundled]

    #expect(required.primaryTitle == nil)
    for model in models { await model.load() }

    #expect(
      models.map(\.primaryTitle) == [
        "Sign in with Acme", "Sign in with Shop", "Install", "Install", "Sign in with Linear",
        "Connect a Slack Workspace…", "Install",
      ])
    #expect(
      models.map(\.skipTitle) == [nil, "Use Without Signing In", nil, nil, nil, nil, nil])
  }

  @Test("Signing in opens the browser before the plugin is installed, then hands that browser the sign-in")
  func signInOpensBrowserFirst() async throws {
    let transport = ConnectTransport()
    transport.respond("GET /v1/plugins/catalog/acme/sign-in", with: #"{"oauth":"required"}"#)
    let presenter = FakeWebSignIn()
    let host = ConnectHost()
    let model = PluginConnectModel(
      entry: try Self.entry(Self.remote(id: "acme", name: "Acme")), client: Self.client(transport), host: host.host,
      webSignIn: presenter)
    await model.load()

    let running = Task { await model.run(.finishSetup) }
    await host.installing.wait()
    let opened = try #require(presenter.urls.first)
    #expect(opened.path.hasPrefix("/v1/sign-in/"))
    #expect(URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "Acme")
    #expect(host.installed.isEmpty)

    host.finishInstall(with: try Self.server())
    #expect(await running.value)
    await host.signingIn.wait()

    #expect(host.authTypes == ["oauth"])
    #expect(host.installed.map(\.id) == ["mcp-1"])
    #expect(host.browsers.map { "/v1/sign-in/\($0.ticket ?? "")" } == [opened.path])
    #expect(presenter.urls.count == 1)
  }

  @Test("For a plugin that is already installed the sheet only connects: no install, no skip, browser at once")
  func connectsInstalledPlugin() async throws {
    let presenter = FakeWebSignIn()
    let host = ConnectHost()
    let model = PluginConnectModel(
      entry: try Self.entry(Self.remote(id: "acme", name: "Acme")), installed: try Self.server(),
      client: Self.client(ConnectTransport()), host: host.host, webSignIn: presenter)
    await model.load()

    #expect(model.primaryTitle == "Sign in with Acme" && model.skipTitle == nil)
    #expect(await model.run(.finishSetup))
    await host.signingIn.wait()

    #expect(host.authTypes.isEmpty)
    #expect(host.installed.map(\.id) == ["mcp-1"])
    #expect(host.browsers.count == 1 && presenter.urls.count == 1)
  }

  @Test("Using an optional plugin without signing in installs it and opens nothing")
  func skippingSignIn() async throws {
    let transport = ConnectTransport()
    transport.respond("GET /v1/plugins/catalog/shop/sign-in", with: #"{"oauth":"optional"}"#)
    let presenter = FakeWebSignIn()
    let host = ConnectHost()
    let model = PluginConnectModel(
      entry: try Self.entry(Self.remote(id: "shop", name: "Shop")), client: Self.client(transport), host: host.host,
      webSignIn: presenter)
    await model.load()

    let running = Task { await model.run(.skipSignIn) }
    await host.installing.wait()
    host.finishInstall(with: try Self.server(authType: "none", state: "connected"))

    #expect(await running.value)
    #expect(host.authTypes == ["none"])
    #expect(presenter.urls.isEmpty)
    #expect(host.browsers.isEmpty)
  }

  @Test("When the install fails, the sheet stays up with the reason and the waiting browser is told")
  func installFailureAbandonsBrowser() async throws {
    let transport = ConnectTransport()
    transport.respond("GET /v1/plugins/catalog/acme/sign-in", with: #"{"oauth":"required"}"#)
    let presenter = FakeWebSignIn()
    let host = ConnectHost()
    let model = PluginConnectModel(
      entry: try Self.entry(Self.remote(id: "acme", name: "Acme")), client: Self.client(transport), host: host.host,
      webSignIn: presenter)
    await model.load()

    let running = Task { await model.run(.finishSetup) }
    await host.installing.wait()
    let opened = try #require(presenter.urls.first)
    transport.respond("DELETE \(opened.path)", with: #"{"abandoned":true}"#)
    host.failInstall(with: ConnectFailure())

    #expect(await running.value == false)
    #expect(model.errorMessage == "Acme isn't available in your region")
    #expect(!model.isWorking)
    #expect(!presenter.isOpen)
    #expect(transport.requested("DELETE \(opened.path)"))
    #expect(host.browsers.isEmpty)
  }

  private static func client(_ transport: ConnectTransport) -> CodevisorServerClient {
    CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport))
  }

  private static func entry(_ json: String) throws -> ServerPluginCatalogEntry {
    try JSONDecoder().decode(ServerPluginCatalogEntry.self, from: Data(json.utf8))
  }

  private static func server(
    authType: String = "oauth", state: String = "needsAuthorization"
  ) throws
    -> ServerMcpServer
  {
    let json = """
      {"id":"mcp-1","name":"Acme","transport":"http","args":[],"enabled":true,"authType":"\(authType)",\
      "connectionState":"\(state)","toolCount":0,"createdAt":"","updatedAt":""}
      """
    return try JSONDecoder().decode(ServerMcpServer.self, from: Data(json.utf8))
  }

  private static func remote(id: String, name: String) -> String {
    """
    {"id":"\(id)","name":"\(name)","description":"","publisher":"Example","version":"1","transport":"http",\
    "install":{"kind":"remote","url":"https://mcp.example","fields":[]},"capabilities":{}}
    """
  }

  private static func bundled(accounts: String?) -> String {
    """
    {"id":"bundled","name":"Bundled","description":"","publisher":"Codevisor","version":"1","transport":"stdio",\
    "install":{"kind":"bundled"},"capabilities":{}\(accounts.map { #","accounts":\#($0)"# } ?? "")}
    """
  }

  private static let linearAccounts = """
    {"label":"Linear workspace","fields":[],"oauth":{"provider":"linear","authorizeUrl":"https://linear.app/a",\
    "tokenUrl":"https://linear.app/t","scopes":["read"],"client":"installed"}}
    """

  private static let slackAccounts = """
    {"label":"Slack workspace","fields":[{"key":"token","label":"Token","type":"secret","required":true}],\
    "guide":{"title":"Connect a Slack Workspace","summary":"s","steps":[]}}
    """
}

private struct ConnectFailure: LocalizedError {
  var errorDescription: String? { "Acme isn't available in your region" }
}

@MainActor
private final class ConnectHost {
  let installing = TestSignal()
  let signingIn = TestSignal()
  private(set) var authTypes: [String?] = []
  private(set) var installed: [ServerMcpServer] = []
  private(set) var browsers: [PluginSignInBrowser] = []
  private var pending: CheckedContinuation<ServerMcpServer, any Error>?

  var host: PluginConnectHost {
    PluginConnectHost(
      install: { [self] _, authType in
        authTypes.append(authType)
        return try await withCheckedThrowingContinuation { continuation in
          pending = continuation
          installing.signal()
        }
      },
      didInstall: { [self] in installed.append($0) },
      signIn: { [self] _, browser in
        browsers.append(browser)
        signingIn.signal()
      },
      signInFailed: { _ in }
    )
  }

  func finishInstall(with server: ServerMcpServer) {
    pending?.resume(returning: server)
    pending = nil
  }

  func failInstall(with error: any Error) {
    pending?.resume(throwing: error)
    pending = nil
  }
}

private final class ConnectTransport: ServerRequestTransport, Sendable {
  private let routes = Mutex<[String: String]>([:])
  private let seen = Mutex<Set<String>>([])

  func respond(_ route: String, with body: String) {
    routes.withLock { $0[route] = body }
  }

  func requested(_ route: String) -> Bool {
    seen.withLock { $0.contains(route) }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let route = "\(request.httpMethod ?? "GET") \(url.path)"
    seen.withLock { _ = $0.insert(route) }
    let body = routes.withLock { $0[route] }
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil))
    return (Data((body ?? #"{"error":"missing"}"#).utf8), response)
  }
}
