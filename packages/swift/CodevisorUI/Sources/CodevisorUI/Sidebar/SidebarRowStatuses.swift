import CodevisorCore
import Foundation

public struct SidebarRowStatuses {
  private let statuses: [UUID: SidebarRowStatus]

  public init(
    _ items: [WorkspaceSidebarItem], chats: [ChatSession], mainChat: (WorkspaceSidebarItem) -> ChatSession?,
    activity: (ChatSession) -> SidebarChatActivity,
    chatless: (WorkspaceSidebarItem) -> SidebarChatActivity? = { _ in nil }
  ) {
    var busyOwners: Set<UUID> = []
    for chat in chats where !chat.isArchived {
      guard let owner = chat.ownerAgent, !busyOwners.contains(owner.agentId), activity(chat).isBusy else { continue }
      busyOwners.insert(owner.agentId)
    }
    var statuses: [UUID: SidebarRowStatus] = [:]
    for item in items {
      let main = mainChat(item)
      let own = main.map(activity) ?? chatless(item)
      let hasBusySubAgent = main.map { busyOwners.contains($0.id) } ?? false
      statuses[item.id] = Self.status(own: own, hasBusySubAgent: hasBusySubAgent)
    }
    self.statuses = statuses
  }

  public func status(of workspaceId: UUID) -> SidebarRowStatus? {
    statuses[workspaceId]
  }

  public static func status(
    of chat: ChatSession, among chats: [ChatSession], activity: (ChatSession) -> SidebarChatActivity
  ) -> SidebarRowStatus? {
    let hasBusySubAgent = chats.contains {
      !$0.isArchived && $0.ownerAgent?.agentId == chat.id && activity($0).isBusy
    }
    return status(own: activity(chat), hasBusySubAgent: hasBusySubAgent)
  }

  private static func status(own: SidebarChatActivity?, hasBusySubAgent: Bool) -> SidebarRowStatus? {
    switch own?.request {
    case .input: return .input
    case .approval: return .approval
    case nil: break
    }
    if own?.isSettingUp == true { return .settingUp }
    if let own, own.isWorking { return .working(since: own.workingSince) }
    if hasBusySubAgent { return .waiting }
    switch own?.failure {
    case .error: return .failed
    case .usageLimit: return .limited
    case nil: return nil
    }
  }
}
