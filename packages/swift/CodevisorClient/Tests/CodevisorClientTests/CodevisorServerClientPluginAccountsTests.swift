import ACPKit
import Foundation
import Testing

@testable import CodevisorClient

@Suite("Server client plugin account endpoints")
struct CodevisorServerClientPluginAccountsTests {
  @Test("A new account is POSTed to the plugin's accounts and an edit is PUT to that account")
  func saveAccount() async throws {
    let transport = AccountsTransport(response: Self.accountJSON)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let draft = ServerPluginAccountDraft(label: "Prod", values: ["url": .string("https://g.example")])

    _ = try await client.savePluginAccount(serverId: "mcp-1", accountId: nil, draft: draft)
    let saved = try await client.savePluginAccount(serverId: "mcp-1", accountId: "acc-1", draft: draft)

    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["POST", "PUT"])
    #expect(requests.map(\.url?.path) == ["/v1/plugins/mcp-1/accounts", "/v1/plugins/mcp-1/accounts/acc-1"])
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(requests[0].httpBody))
    #expect(body == ["label": .string("Prod"), "values": .object(["url": .string("https://g.example")])])
    #expect(saved.secretsSet == ["token"])
    #expect(saved.values == ["url": .string("https://g.example")])
  }

  @Test("A catalog entry is looked up by its registry name as one path segment, with its account spec")
  func catalogEntry() async throws {
    let transport = AccountsTransport(response: Self.entryJSON)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))

    let entry = try await client.pluginCatalogEntry(id: "io.github.acme/mail")

    let request = try #require(await transport.requests.first)
    #expect(request.url?.absoluteString.hasSuffix("/v1/plugins/catalog/io.github.acme%2Fmail") == true)
    #expect(entry.accounts?.oauth?.provider == "google")
    #expect(entry.accounts?.fields.map(\.type) == [.string, .secret])
    #expect(entry.installFields.isEmpty)
  }

  @Test("Sign-in starts sent to a machine on another device say so, so it won't answer with a loopback callback")
  func crossDeviceSignInStarts() async throws {
    let transport = AccountsTransport(response: #"{"flowId":"f","authorizationUrl":"https://a.example"}"#)
    let here = CodevisorServerClient(config: .init(requestTransport: transport), isOnThisDevice: true)
    let elsewhere = CodevisorServerClient(config: .init(requestTransport: transport), isOnThisDevice: false)

    _ = try await here.startMcpOAuth(id: "mcp-1", ticket: "t1")
    _ = try await elsewhere.startMcpOAuth(id: "mcp-1", ticket: nil)
    _ = try await here.startPluginAccountOAuth(serverId: "mcp-1", request: .init(), ticket: nil)
    _ = try await elsewhere.startPluginAccountOAuth(serverId: "mcp-1", request: .init(), ticket: "t2")

    let queries = await transport.requests.map { request in
      URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
        .filter { $0.name != "app" }.map { "\($0.name)=\($0.value ?? "")" } ?? []
    }
    #expect(queries == [["ticket=t1"], ["crossDevice=1"], [], ["ticket=t2", "crossDevice=1"]])
  }

  private static let accountJSON = """
    {"id":"acc-1","plugin":"grafana","label":"Prod","method":"fields","values":{"url":"https://g.example"},
    "secretsSet":["token"],"status":"ok","createdAt":"2026-10-27T00:00:00.000Z"}
    """

  private static let entryJSON = """
    {"id":"io.github.acme/mail","name":"Mail","description":"","publisher":"acme","version":"1",
    "source":"registry","transport":"stdio","install":{"kind":"bundled"},"capabilities":{},
    "accounts":{"label":"Google account","oauth":{"provider":"google","authorizeUrl":"a","tokenUrl":"t",
    "scopes":["email"],"client":"byo"},"fields":[{"key":"clientId","label":"Client ID","type":"string",
    "required":true},{"key":"clientSecret","label":"Client secret","type":"secret","required":true}]}}
    """
}

private actor AccountsTransport: ServerRequestTransport {
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
