import CodevisorCore
import Foundation

public struct SidebarRowStatuses {
  private let activities: [UUID: SidebarChatActivity]
  private let children: [UUID: [UUID]]

  public init(_ items: [WorkspaceSidebarItem], activity: (WorkspaceSidebarItem) -> SidebarChatActivity?) {
    var activities: [UUID: SidebarChatActivity] = [:]
    var children: [UUID: [UUID]] = [:]
    for item in items {
      activities[item.id] = activity(item)
      guard let parent = item.parent, parent.isQuiet, parent.workspaceId != item.id else { continue }
      children[parent.workspaceId, default: []].append(item.id)
    }
    self.activities = activities
    self.children = children
  }

  public func status(of workspaceId: UUID) -> SidebarRowStatus? {
    let subtree = [workspaceId] + descendants(of: workspaceId)
    if let asker = first(in: subtree, requesting: .input) { return .input(askingWorkspaceID: asker) }
    if let asker = first(in: subtree, requesting: .approval) { return .approval(askingWorkspaceID: asker) }
    return ownStatus(of: workspaceId, descendants: subtree.dropFirst())
  }

  private func ownStatus(of workspaceId: UUID, descendants: ArraySlice<UUID>) -> SidebarRowStatus? {
    let own = activities[workspaceId]
    if own?.isSettingUp == true { return .settingUp }
    if let own, own.isWorking { return .working(since: own.workingSince) }
    if descendants.contains(where: { activities[$0]?.isBusy == true }) { return .waiting }
    switch own?.failure {
    case .error: return .failed
    case .usageLimit: return .limited
    case nil: return nil
    }
  }

  private func first(in subtree: [UUID], requesting request: SidebarChatActivity.Request) -> UUID? {
    subtree.first { activities[$0]?.request == request }
  }

  private func descendants(of workspaceId: UUID) -> [UUID] {
    var seen: Set<UUID> = [workspaceId]
    var queue = children[workspaceId] ?? []
    var order: [UUID] = []
    while !queue.isEmpty {
      let next = queue.removeFirst()
      guard seen.insert(next).inserted else { continue }
      order.append(next)
      queue.append(contentsOf: children[next] ?? [])
    }
    return order
  }
}
