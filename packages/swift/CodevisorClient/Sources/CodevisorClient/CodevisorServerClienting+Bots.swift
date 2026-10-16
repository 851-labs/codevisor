import Foundation

public extension CodevisorServerClienting {
  func listBots() async throws -> [ServerBot] {
    []
  }

  func createBot(_ request: ServerCreateBotRequest) async throws -> ServerBot {
    throw CodevisorServerClientError.invalidResponse
  }

  func updateBot(id: String, _ request: ServerUpdateBotRequest) async throws -> ServerBot {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteBot(id: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }
}
