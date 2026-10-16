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
}

extension ServerBot {
  static func fixture(
    id: UUID = UUID(),
    name: String = "Helper",
    projectId: UUID = UUID(),
    sessionId: UUID = UUID(),
    workspaceId: UUID = UUID()
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
      projects: [],
      createdAt: "2026-10-15T00:00:00.000Z"
    )
  }
}
