import CodevisorClient
import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceInspectorUsageModel {
  struct Account: Hashable, Sendable {
    let serverId: String
    let harnessId: String
    let accountId: String?

    init(_ chat: ChatSession) {
      serverId = chat.serverId
      harnessId = chat.harnessId
      accountId = chat.harnessAccountId
    }
  }

  private(set) var snapshots: [Account: ServerHarnessUsageLimits] = [:]

  func limits(for chat: ChatSession) -> ServerHarnessUsageLimits? {
    guard let limits = snapshots[Account(chat)], limits.state == "available", !limits.windows.isEmpty
    else { return nil }
    return limits
  }

  func reload(_ chat: ChatSession, client: any CodevisorServerClienting) async {
    guard let limits = try? await client.sessionUsageLimits(id: chat.id) else { return }
    snapshots[Account(chat)] = limits
  }

  func prefetch(_ chats: [ChatSession], client: (String) -> any CodevisorServerClienting) async {
    var accounts = Set(snapshots.keys)
    let pending = chats.filter { accounts.insert(Account($0)).inserted }.map { ($0, client($0.serverId)) }
    await withTaskGroup(of: Void.self) { group in
      for (chat, client) in pending {
        group.addTask { await self.reload(chat, client: client) }
      }
    }
  }
}
