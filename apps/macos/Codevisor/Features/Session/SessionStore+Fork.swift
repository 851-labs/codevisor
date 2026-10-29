import CodevisorCore
import Foundation

extension SessionStore {
  func canFork(_ session: ChatSession) -> Bool {
    guard session.agentSessionId?.isEmpty == false, !isInProgress(session) else { return false }
    if let controller = controllers[SessionKey(session)] { return controller.supportsFork }
    return environment.configCache.harnessCanFork(session.harnessId, onServer: session.serverId)
  }

  func fork(_ session: ChatSession) async -> ChatSession? {
    do {
      let forked = try await environment.machines.client(for: session.serverId).forkSession(id: session.id)
      return try forked.chatSession(serverId: session.serverId)
    } catch {
      ErrorReporter.shared.report("Couldn't fork the chat", error: error)
      return nil
    }
  }
}
