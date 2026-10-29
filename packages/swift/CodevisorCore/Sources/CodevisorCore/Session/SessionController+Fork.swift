import ACPKit
import CodevisorProtocol
import Foundation

extension SessionController {
  public func fork() async -> ChatSession? {
    guard supportsFork, let serverClient, let sessionId = serverSession?.id else { return nil }

    do {
      let forked = try await serverClient.forkSession(id: sessionId)
      return try forked.chatSession(serverId: project.serverId)
    } catch {
      model?.errorMessage = serverErrorMessage(error)
      return nil
    }
  }
}
