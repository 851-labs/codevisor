import ACPKit
import CodevisorCore
import Foundation
import Synchronization
import Testing

@testable import CodevisorUI

@MainActor
struct PluginSetupModelTests {
  @Test("A fields plugin moves from Install to Add Account to ready as the machine catches up")
  func fieldsPluginSteps() async throws {
    let transport = SetupTransport()
    transport.respond("GET /v1/plugins/catalog/grafana", with: Self.grafanaEntry)
    transport.respond("GET /v1/mcps", with: "[]")
    let model = PluginSetupModel(request: try Self.request(auth: "fields"), client: Self.client(transport))

    #expect(model.step == .checking)
    await model.refresh()
    #expect(model.step == .install)
    #expect(model.actionTitle == "Install")

    await model.performPrimaryAction()
    #expect(model.installing?.id == "grafana")

    transport.respond("GET /v1/mcps", with: "[\(Self.server(authType: "none", state: "connected"))]")
    transport.respond("GET /v1/plugins/mcp-1/accounts", with: #"{"accounts":[]}"#)
    await model.refresh()
    #expect(model.step == .signIn)
    #expect(model.actionTitle == "Add Account")

    await model.performPrimaryAction()
    #expect(model.addingAccount?.draft.fields.map(\.key) == ["url"])

    transport.respond("GET /v1/plugins/mcp-1/accounts", with: #"{"accounts":[\#(Self.account)]}"#)
    await model.refresh()
    #expect(model.step == .ready)
    #expect(model.actionTitle == nil)
  }

  @Test("The MCP sign-in sheet closes by itself once the machine reports the plugin connected")
  func mcpSignInClosesOnConnect() async throws {
    let transport = SetupTransport()
    transport.respond("GET /v1/plugins/catalog/grafana", with: Self.remoteEntry)
    transport.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "needsAuthorization"))]")
    transport.respond(
      "POST /v1/mcps/mcp-1/oauth-start", with: #"{"authorizationUrl":"https://auth.example/authorize"}"#)
    let signIn = FakeWebSignIn()
    let model = PluginSetupModel(
      request: try Self.request(auth: "mcpOAuth"), client: Self.client(transport), webSignIn: signIn)
    await model.refresh()
    #expect(model.step == .signIn)
    #expect(model.actionTitle == "Sign In")

    let action = Task { await model.performPrimaryAction() }
    await signIn.presented.wait()
    #expect(signIn.urls.map(\.absoluteString) == ["https://auth.example/authorize"])
    await model.refresh()
    #expect(signIn.isOpen)

    transport.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "connected"))]")
    await model.refresh()
    try #require(!signIn.isOpen)
    await action.value
    #expect(model.step == .ready)
    #expect(!model.isWorking)
  }

  @Test("A card for another machine signs in through this Mac's copy and closes once that machine connects")
  func remoteCardSignsInLocally() async throws {
    let remote = SetupTransport()
    remote.respond("GET /v1/plugins/catalog/grafana", with: Self.remoteEntry)
    remote.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "needsAuthorization"))]")
    let local = SetupTransport()
    local.respond(
      "GET /v1/mcps", with: "[\(Self.server(id: "local-mcp", authType: "oauth", state: "needsAuthorization"))]")
    local.respond(
      "POST /v1/mcps/local-mcp/oauth-start", with: #"{"authorizationUrl":"http://127.0.0.1:49361/authorize"}"#)
    let signIn = FakeWebSignIn()
    let model = PluginSetupModel(
      request: try Self.request(auth: "mcpOAuth"), client: Self.client(remote),
      signInRoute: .localMachine(Self.client(local)), webSignIn: signIn)
    await model.refresh()

    let action = Task { await model.performPrimaryAction() }
    await signIn.presented.wait()
    #expect(signIn.urls.map(\.absoluteString) == ["http://127.0.0.1:49361/authorize"])

    remote.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "connected"))]")
    await model.refresh()
    try #require(!signIn.isOpen)
    await action.value
    #expect(model.step == .ready)
  }

  @Test("Without a Mac to sign in on, the card says where to sign in instead of opening anything")
  func cardWithoutLocalMachine() async throws {
    let transport = SetupTransport()
    transport.respond("GET /v1/plugins/catalog/grafana", with: Self.remoteEntry)
    transport.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "needsAuthorization"))]")
    let signIn = FakeWebSignIn()
    let model = PluginSetupModel(
      request: try Self.request(auth: "mcpOAuth"), client: Self.client(transport), signInRoute: .unavailable,
      webSignIn: signIn)
    await model.refresh()

    await model.performPrimaryAction()

    #expect(signIn.urls.isEmpty)
    #expect(model.step == .signIn)
    #expect(model.errorMessage?.hasPrefix("Sign in to Grafana from Codevisor on your Mac.") == true)
  }

  @Test("A card that can't read the machine's plugins offers Retry and recovers")
  func cardRetriesAfterLoadFailure() async throws {
    let transport = SetupTransport()
    transport.respond("GET /v1/plugins/catalog/grafana", with: Self.remoteEntry)
    transport.respond("GET /v1/mcps", with: #"{"error":"database busy"}"#, status: 503)
    let model = PluginSetupModel(request: try Self.request(auth: "mcpOAuth"), client: Self.client(transport))

    await model.refresh()
    #expect(model.step == .failed)
    #expect(model.actionTitle == "Retry")
    #expect(model.errorMessage == "database busy")

    transport.respond("GET /v1/mcps", with: "[\(Self.server(authType: "oauth", state: "needsAuthorization"))]")
    await model.performPrimaryAction()
    #expect(model.step == .signIn)
    #expect(model.errorMessage == nil)
  }

  @Test("A plugin account sign-in sheet closes by itself once the new account shows up")
  func accountSignInClosesOnNewAccount() async throws {
    let transport = SetupTransport()
    transport.respond("GET /v1/plugins/mcp-1/accounts", with: #"{"accounts":[]}"#)
    transport.respond(
      "POST /v1/plugins/mcp-1/accounts/oauth/start",
      with: #"{"flowId":"flow-1","authorizationUrl":"https://accounts.example/authorize"}"#)
    let signIn = FakeWebSignIn()
    let spec = ServerPluginAccountSpec(label: "Google account", oauth: ServerPluginOAuthSpec(provider: "google"))
    let server = try JSONDecoder().decode(
      ServerMcpServer.self, from: Data(Self.server(authType: "none", state: "connected").utf8))
    let accounts = PluginAccountsModel(server: server, client: Self.client(transport), spec: spec, webSignIn: signIn)
    await accounts.load()

    let signingIn = Task { await accounts.signIn() }
    await signIn.presented.wait()
    await accounts.reload()
    #expect(signIn.isOpen)

    transport.respond("GET /v1/plugins/mcp-1/accounts", with: #"{"accounts":[\#(Self.account)]}"#)
    await accounts.reload()
    try #require(!signIn.isOpen)
    await signingIn.value
    #expect(accounts.accounts.map(\.id) == ["acc-1"])
  }

  @Test("Answering Not Now or cancelling declines; any other outcome counts as set up")
  func resolution() {
    let declined = TranscriptQuestion.Answer(
      outcome: .answered, entries: ["plugin_setup": .init(answers: [PluginSetupResolution.declineLabel])])

    #expect(PluginSetupResolution(declined) == .declined)
    #expect(PluginSetupResolution(.init(outcome: .cancelled)) == .declined)
    #expect(PluginSetupResolution(.init(outcome: .autoResolved)) == .connected)
    #expect(PluginSetupResolution(nil) == nil)
  }

  private static func client(_ transport: SetupTransport) -> CodevisorServerClient {
    CodevisorServerClient(config: CodevisorServerConfig(requestTransport: transport))
  }

  private static func request(auth: String) throws -> ServerPluginSetupRequest {
    let json = """
      {"plugin":"grafana","catalogId":"grafana","name":"Grafana","reason":"Watch alerts","auth":"\(auth)",\
      "capabilities":{},"machine":{"id":"m-1","name":"Studio"}}
      """
    let questions = try JSONDecoder().decode(
      [QuestionSpec].self,
      from: Data(
        #"[{"id":"plugin_setup","question":"q","options":[],"allowsOther":false,"pluginSetup":\#(json)}]"#.utf8))
    return try #require(ServerPluginSetupRequest.decoded(from: questions))
  }

  private static func server(id: String = "mcp-1", authType: String, state: String) -> String {
    """
    {"id":"\(id)","name":"Grafana","transport":"stdio","args":[],"enabled":true,"authType":"\(authType)",\
    "connectionState":"\(state)","toolCount":0,"catalogId":"grafana","createdAt":"","updatedAt":""}
    """
  }

  private static let grafanaEntry = """
    {"id":"grafana","name":"Grafana","description":"","publisher":"Codevisor","version":"1","transport":"stdio",\
    "install":{"kind":"bundled"},"capabilities":{},"accounts":{"label":"Grafana instance","fields":[\
    {"key":"url","label":"Grafana URL","type":"url","required":true}]}}
    """

  private static let remoteEntry = """
    {"id":"grafana","name":"Grafana","description":"","publisher":"Codevisor","version":"1","transport":"http",\
    "install":{"kind":"remote","url":"https://mcp.example","fields":[]},"capabilities":{}}
    """

  private static let account = """
    {"id":"acc-1","plugin":"grafana","method":"fields","values":{},"secretsSet":[],"status":"ok","createdAt":""}
    """
}

private final class SetupTransport: ServerRequestTransport, Sendable {
  private let routes = Mutex<[String: (status: Int, body: String)]>([:])

  func respond(_ route: String, with body: String, status: Int = 200) {
    routes.withLock { $0[route] = (status, body) }
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try #require(request.url)
    let route = "\(request.httpMethod ?? "GET") \(url.path)"
    let reply = try #require(routes.withLock { $0[route] }, "Unexpected request \(route)")
    let response = try #require(
      HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil))
    return (Data(reply.body.utf8), response)
  }
}
