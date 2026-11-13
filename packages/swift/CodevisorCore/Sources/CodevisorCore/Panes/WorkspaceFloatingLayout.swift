import Foundation

public struct WorkspaceFloatingLayout: Equatable {
  public let floating: Set<UUID>
  public let stale: Set<UUID>

  public init(workspace: Workspace, flagged: Set<UUID>) {
    let floating = workspace.centerTabs.map { Self.floatingLeaves(in: $0, flagged: flagged) }
    self.floating = floating.reduce(into: Set<UUID>()) { $0.formUnion($1) }
    stale = flagged.subtracting(self.floating)
  }

  public func canFloat(_ leafId: UUID, in tree: SplitNode) -> Bool {
    let docked = Set(tree.allGroups.map(\.id)).subtracting(floating)
    return docked.contains(leafId) && docked.count > 1
  }

  private static func floatingLeaves(in tab: WorkspaceTab, flagged: Set<UUID>) -> Set<UUID> {
    let leaves = Set(tab.root.allGroups.map(\.id))
    let floating = leaves.intersection(flagged)
    return floating == leaves ? [] : floating
  }
}
