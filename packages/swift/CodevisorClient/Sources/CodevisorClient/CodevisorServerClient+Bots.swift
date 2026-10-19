import Foundation

extension CodevisorServerClient {
  public func listBots() async throws -> [ServerBot] {
    try await get("/v1/bots")
  }

  public func createBot(_ request: ServerCreateBotRequest) async throws -> ServerBot {
    try await send("/v1/bots", method: "POST", body: request)
  }

  public func updateBot(id: String, _ request: ServerUpdateBotRequest) async throws -> ServerBot {
    try await send("/v1/bots/\(pathComponent(id))", method: "PATCH", body: request)
  }

  public func deleteBot(id: String) async throws {
    try await sendNoResponse("/v1/bots/\(pathComponent(id))", method: "DELETE")
  }

  public func botConversation(sessionId: UUID, before: Int?, limit: Int) async throws -> ServerBotConversationPage {
    var components = URLComponents()
    components.path = "/v1/sessions/\(sessionId.uuidString)/conversation"
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    if let before {
      components.queryItems?.append(URLQueryItem(name: "before", value: String(before)))
    }
    guard let path = components.string else { throw CodevisorServerClientError.invalidURL("conversation") }
    return try await get(path)
  }
}
