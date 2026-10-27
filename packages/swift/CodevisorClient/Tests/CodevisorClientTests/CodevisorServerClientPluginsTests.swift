import ACPKit
import Foundation
import Testing

@testable import CodevisorClient

@Suite("Server client plugin endpoints")
struct CodevisorServerClientPluginsTests {
  @Test("The catalog decodes entries with their capability digest")
  func catalogDecoding() async throws {
    let transport = PluginTransport(response: Self.catalogJSON)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    let entries = try await client.listPluginCatalog(query: " ")

    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/v1/plugins/catalog")
    #expect(request.url?.query == nil)
    let grafana = try #require(entries.first)
    #expect(grafana.publisher == "Codevisor")
    #expect(grafana.capabilities.tools == [ServerPluginToolDigest(name: "alerts", effects: "read", app: true)])
    #expect(grafana.capabilities.panes == [ServerPluginPane(type: "board", title: "Alerts", resourceUri: "ui://g/a")])
    #expect(grafana.capabilities.skills.isEmpty)
    #expect(!grafana.capabilities.isEmpty)
  }

  @Test("A catalog search sends the trimmed query")
  func catalogSearch() async throws {
    let transport = PluginTransport(response: #"{"entries":[]}"#)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    _ = try await client.listPluginCatalog(query: " linear & co ")

    let request = try #require(await transport.requests.first)
    let components = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(components.queryItems == [URLQueryItem(name: "query", value: "linear & co")])
  }

  @Test("Installing a registry plugin encodes its name as one path segment and sends the field values")
  func catalogInstall() async throws {
    let transport = PluginTransport(response: Self.serverJSON)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    let server = try await client.installCatalogPlugin(
      id: "io.github.acme/grafana", values: ["env:TOKEN": .string("t"), "header:Port": .number(3)])

    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/v1/plugins/catalog/io.github.acme%2Fgrafana/install") == true)
    let body = try JSONDecoder().decode([String: [String: JSONValue]].self, from: #require(request.httpBody))
    #expect(body == ["values": ["env:TOKEN": .string("t"), "header:Port": .number(3)]])
    #expect(server.catalogId == "grafana")
    #expect(server.catalogVersion == "1.0.0")
    #expect(server.capabilityDigest?.events == [ServerPluginEventDigest(name: "alert.firing")])
  }

  @Test("A pane token request names the plugin row and pane type and sends only the given context")
  func paneToken() async throws {
    let transport = PluginTransport(response: #"{"url":"/v1/plugins/apps/abc","expiresAt":"2026-10-27T00:00:00.000Z"}"#)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    let token = try await client.issuePluginPaneToken(
      serverId: "mcp-1", paneType: "board", request: ServerPluginPaneTokenRequest(themeMode: "dark"))

    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/v1/plugins/mcp-1/panes/board/token")
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body == ["themeMode": .string("dark")])
    #expect(token.url == "/v1/plugins/apps/abc")
  }

  @Test("An inline app token is a bodiless POST that names the view as one path segment")
  func appViewToken() async throws {
    let transport = PluginTransport(
      response: #"{"url":"/v1/plugins/apps/a%2Fb?token=t","expiresAt":"2026-10-27T00:10:00.000Z"}"#)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    let token = try await client.issuePluginAppViewToken(viewId: "a/b")

    let request = try #require(await transport.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString.hasSuffix("/v1/plugins/apps/a%2Fb/token") == true)
    #expect(request.httpBody == nil)
    #expect(token.url == "/v1/plugins/apps/a%2Fb?token=t")
  }

  @Test("A pane token URL is appended to the machine's base unless it is already absolute")
  func paneTokenURL() throws {
    let base = try #require(URL(string: "https://relay.example/m/1/"))
    let relative = ServerPluginPaneTokenResponse(url: "/v1/plugins/apps/abc?t=1", expiresAt: "")
    let absolute = ServerPluginPaneTokenResponse(url: "http://127.0.0.1:4000/app", expiresAt: "")

    #expect(relative.resolvedURL(base: base)?.absoluteString == "https://relay.example/m/1/v1/plugins/apps/abc?t=1")
    #expect(absolute.resolvedURL(base: base)?.absoluteString == "http://127.0.0.1:4000/app")
  }

  @Test("A plugin row without a digest, or with an empty one, has no capability digest")
  func serverWithoutCapabilities() throws {
    let bare = """
      {"id":"m","name":"M","transport":"http","args":[],"enabled":true,"authType":"none",\
      "connectionState":"connected","toolCount":0,"createdAt":"","updatedAt":""}
      """
    let empty = bare.replacingOccurrences(of: #""toolCount":0"#, with: #""toolCount":0,"capabilities":{"tools":[]}"#)

    let servers = try [bare, empty].map { try JSONDecoder().decode(ServerMcpServer.self, from: Data($0.utf8)) }

    #expect(servers.map(\.catalogId) == [nil, nil])
    #expect(servers[1].capabilities == ServerPluginCapabilities())
    #expect(servers.allSatisfy { $0.capabilityDigest == nil })
  }

  private static let catalogJSON = """
    {"entries":[{"id":"grafana","name":"Grafana","description":"Alerts","publisher":"Codevisor",
    "version":"1.0.0","transport":"stdio","capabilities":{"tools":[{"name":"alerts","effects":"read","app":true}],
    "events":[],"skills":[],"panes":[{"type":"board","title":"Alerts","resourceUri":"ui://g/a"}],"ingress":[]}}]}
    """

  private static let serverJSON = """
    {"id":"mcp-1","name":"Grafana","kind":"custom","transport":"stdio","args":[],"enabled":true,
    "authType":"none","connectionState":"connected","toolCount":1,"catalogId":"grafana","catalogVersion":"1.0.0",
    "capabilities":{"tools":[],"events":[{"name":"alert.firing"}],"skills":[],"panes":[],"ingress":[]},
    "createdAt":"","updatedAt":""}
    """
}

private actor PluginTransport: ServerRequestTransport {
  let response: String
  var requests: [URLRequest] = []

  init(response: String) {
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (
      Data(response.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
