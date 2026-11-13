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

  func forkBot(id: String, _ request: ServerForkBotRequest) async throws -> ServerBot {
    throw CodevisorServerClientError.invalidResponse
  }

  func botMascotOptions() async throws -> ServerBotMascotOptions {
    throw CodevisorServerClientError.invalidResponse
  }

  func botMascotArt(_ art: ServerBotMascotArt) async throws -> Data {
    throw CodevisorServerClientError.invalidResponse
  }

  func addBotProject(botId: String, projectId: String) async throws -> ServerBot {
    throw CodevisorServerClientError.invalidResponse
  }

  func removeBotProject(botId: String, projectId: String) async throws -> ServerBot {
    throw CodevisorServerClientError.invalidResponse
  }

  func deleteBot(id: String) async throws {
    throw CodevisorServerClientError.invalidResponse
  }

  func botConversation(sessionId: UUID, before: Int?, limit: Int) async throws -> ServerBotConversationPage {
    throw CodevisorServerClientError.invalidResponse
  }

  func botThreads(botId: String) async throws -> [ServerThread] {
    []
  }

  func threadMessages(threadId: String, before: Int?, limit: Int) async throws -> ServerThreadMessagePage {
    throw CodevisorServerClientError.invalidResponse
  }
}
