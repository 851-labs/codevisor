import Foundation

@testable import CodevisorCore

extension SyncFakeServerClient {
  func setBots(_ bots: [ServerBot]) {
    lock.withLock { _bots = bots }
  }

  func listBots() async throws -> [ServerBot] {
    lock.withLock { _bots }
  }

  func createBot(_ request: ServerCreateBotRequest) async throws -> ServerBot {
    guard let botCreateHandler else { throw CodevisorServerClientError.invalidResponse }
    let bot = try await botCreateHandler(request)
    lock.withLock { _bots.append(bot) }
    return bot
  }

  func addBotProject(botId: String, projectId: String) async throws -> ServerBot {
    try changeBot(botId) { bot in
      bot.projects.append(
        ServerBotProject(
          projectId: projectId,
          folderName: projectId,
          branch: "codevisor/bot-helper",
          path: "\(bot.rootPath)/\(projectId)"
        )
      )
    }
  }

  func removeBotProject(botId: String, projectId: String) async throws -> ServerBot {
    try changeBot(botId) { bot in bot.projects.removeAll { $0.projectId == projectId } }
  }

  private func changeBot(_ botId: String, _ change: (inout ServerBot) -> Void) throws -> ServerBot {
    try lock.withLock {
      if let botProjectError { throw botProjectError }
      guard let index = _bots.firstIndex(where: { $0.id == botId }) else {
        throw CodevisorServerClientError.invalidResponse
      }
      change(&_bots[index])
      return _bots[index]
    }
  }
}

extension ServerBot {
  static func fixture(
    id: UUID = UUID(),
    name: String = "Helper",
    projectId: UUID = UUID(),
    sessionId: UUID = UUID(),
    workspaceId: UUID = UUID(),
    projectIds: [UUID] = []
  ) -> ServerBot {
    ServerBot(
      id: id.uuidString.lowercased(),
      serverId: "server-a",
      name: name,
      symbolName: "sparkles",
      harnessId: "codex",
      projectId: projectId.uuidString.lowercased(),
      sessionId: sessionId.uuidString.lowercased(),
      workspaceId: workspaceId.uuidString.lowercased(),
      rootPath: "/tmp/codevisor/bots/helper",
      projects: projectIds.map { id in
        ServerBotProject(
          projectId: id.uuidString.lowercased(),
          folderName: id.uuidString.lowercased(),
          branch: "codevisor/bot-helper",
          path: "/tmp/codevisor/bots/helper/\(id.uuidString.lowercased())"
        )
      },
      createdAt: "2026-10-15T00:00:00.000Z"
    )
  }
}
