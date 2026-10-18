import Foundation
import Testing

@testable import CodevisorClient

struct ServerSessionContextTests {
  @Test("A running session's context decodes, and a session without one reads as nil")
  func readsContextOrNothing() async throws {
    let id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let live = CodevisorServerClient(config: .init(requestTransport: ContextTransport(body: ContextTransport.live)))
    let context = try #require(try await live.sessionContext(id: id))
    #expect(context.model == "claude-opus-5-5")
    #expect(context.categories.map(\.name) == ["Messages", "MCP tools (deferred)"])
    #expect(context.categories.last?.isDeferred == true)
    #expect(context.mcpTools.first?.serverName == "linear")

    let idle = CodevisorServerClient(config: .init(requestTransport: ContextTransport(body: "null")))
    #expect(try await idle.sessionContext(id: id) == nil)
  }
}

private actor ContextTransport: ServerRequestTransport {
  static let live = """
    {"model":"claude-opus-5-5","totalTokens":220000,"maxTokens":1000000,
     "categories":[{"name":"Messages","tokens":219800,"color":"permission"},
       {"name":"MCP tools (deferred)","tokens":247700,"isDeferred":true}],
     "mcpTools":[{"name":"mcp__linear__list_issues","serverName":"linear","tokens":912,"isLoaded":true}]}
    """

  let body: String

  init(body: String) {
    self.body = body
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
