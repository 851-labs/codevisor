import CodevisorCore
import Foundation
import Testing

@testable import CodevisorUI

@MainActor
struct PluginListsModelTests {
  @Test("A plugin's list rows follow Tools, Skills, Events, Panes and leave out the empty ones")
  func capabilityRowsSkipEmptyLists() throws {
    let server = try Self.server(
      capabilities: #"{"tools":[{"name":"a"},{"name":"b"}],"events":[{"name":"e"}],"panes":[]}"#)
    let model = PluginListsModel(serverId: server.id, client: try Self.client())

    #expect(
      model.summaries(for: server) == [
        PluginListSummary(page: .tools, count: 2), PluginListSummary(page: .events, count: 1),
      ])
  }

  @Test("A server without a capability digest always shows a Tools row, even before any tools load")
  func liveToolsRowAlwaysShows() throws {
    let server = try Self.server(capabilities: nil)
    let model = PluginListsModel(serverId: server.id, client: try Self.client())

    #expect(model.summaries(for: server) == [PluginListSummary(page: .tools, count: 0)])
  }

  private static func client() throws -> CodevisorServerClient {
    CodevisorServerClient(config: CodevisorServerConfig(baseURL: try #require(URL(string: "https://studio.example"))))
  }

  private static func server(capabilities: String?) throws -> ServerMcpServer {
    let json = """
      {"id":"mcp-1","name":"Linear","transport":"http","args":[],"enabled":true,"authType":"none",\
      "connectionState":"connected","toolCount":0,"createdAt":"","updatedAt":""\
      \(capabilities.map { #","capabilities":\#($0)"# } ?? "")}
      """
    return try JSONDecoder().decode(ServerMcpServer.self, from: Data(json.utf8))
  }
}
