import Foundation

extension Workspace {
  public var effectiveSidebarPosition: String {
    sidebarPosition.flatMap { WorkspacePosition.isValid($0) ? $0 : nil }
      ?? WorkspacePosition.initial(createdAt: createdAt, id: id)
  }
}

/// One shared comparator for every client's visible subset. Hidden workspaces
/// retain their keys; reordering never republishes a list of other identities.
public enum WorkspaceSidebarOrder {
  public static func precedes(_ left: Workspace, _ right: Workspace) -> Bool {
    if left.effectiveSidebarPosition != right.effectiveSidebarPosition {
      return left.effectiveSidebarPosition < right.effectiveSidebarPosition
    }
    if left.serverId != right.serverId { return left.serverId < right.serverId }
    return left.id.uuidString < right.id.uuidString
  }

  public static func position(for id: UUID, in visibleIDs: [UUID], workspaces: [Workspace]) -> String? {
    let byID = Dictionary(workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var seen: Set<UUID> = []
    let ids = visibleIDs.filter { byID[$0] != nil && seen.insert($0).inserted }
    guard let index = ids.firstIndex(of: id) else { return nil }
    let lower = index > 0 ? byID[ids[index - 1]]?.effectiveSidebarPosition : nil
    let upper = index + 1 < ids.count ? byID[ids[index + 1]]?.effectiveSidebarPosition : nil
    return WorkspacePosition.between(lower, upper, id: id)
  }
}
