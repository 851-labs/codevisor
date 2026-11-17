import Foundation

public struct SidebarSelectionTarget: Equatable, Sendable {
  public let workspaceID: UUID
  public let tabID: UUID
  public let isArchived: Bool

  public init(workspaceID: UUID, tabID: UUID, isArchived: Bool) {
    self.workspaceID = workspaceID
    self.tabID = tabID
    self.isArchived = isArchived
  }
}

public struct SidebarRevealedSelection: Equatable, Sendable {
  public let workspaceID: UUID
  public let tabID: UUID?

  public init(workspaceID: UUID, tabID: UUID?) {
    self.workspaceID = workspaceID
    self.tabID = tabID
  }
}

public enum SidebarSelectionSync {
  public static func revealed(
    showing target: SidebarSelectionTarget?, unrevealedRowIDs: Set<SidebarRowID>
  ) -> SidebarRevealedSelection? {
    guard let target else { return nil }

    if target.isArchived { return SidebarRevealedSelection(workspaceID: target.workspaceID, tabID: nil) }
    if unrevealedRowIDs.contains(.workspace(target.workspaceID)) { return nil }
    return SidebarRevealedSelection(workspaceID: target.workspaceID, tabID: target.tabID)
  }

  public static func selectedRow(
    showing target: SidebarSelectionTarget?, rowIDs: Set<SidebarRowID>
  ) -> SidebarRowID? {
    guard let target else { return nil }

    let tabRow = SidebarRowID.tab(target.tabID)
    return rowIDs.contains(tabRow) ? tabRow : .workspace(target.workspaceID)
  }
}
