import CodevisorCore
import Foundation
import Testing

@testable import CodevisorUI

@MainActor
struct McpOAuthSignInTests {
  @Test("The sign-in sheet closes once the server it's signing in to reports connected on that machine")
  func closesOnConnected() async throws {
    let presenter = FakeWebSignIn()
    let signIn = McpOAuthSignIn(presenter: presenter)
    let url = try #require(URL(string: "https://auth.example/authorize"))
    let running = Task { await signIn.run(url, serverId: "mcp-1", on: "studio") }
    await presenter.presented.wait()

    signIn.closeIfConnected([try Self.server("mcp-1", state: "needsAuthorization")], on: "studio")
    signIn.closeIfConnected([try Self.server("mcp-1", state: "connected")], on: "laptop")
    signIn.closeIfConnected([try Self.server("mcp-2", state: "connected")], on: "studio")
    #expect(presenter.isOpen)

    signIn.closeIfConnected([try Self.server("mcp-1", state: "connected")], on: "studio")
    try #require(!presenter.isOpen)
    await running.value

    signIn.closeIfConnected([try Self.server("mcp-1", state: "connected")], on: "studio")
    #expect(presenter.closeCount == 1)
  }

  private static func server(_ id: String, state: String) throws -> ServerMcpServer {
    let json = """
      {"id":"\(id)","name":"Linear","transport":"http","args":[],"enabled":true,"authType":"oauth",\
      "connectionState":"\(state)","toolCount":0,"createdAt":"","updatedAt":""}
      """
    return try JSONDecoder().decode(ServerMcpServer.self, from: Data(json.utf8))
  }
}
