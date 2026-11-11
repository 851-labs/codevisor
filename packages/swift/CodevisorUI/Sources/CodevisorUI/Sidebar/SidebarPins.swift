import CodevisorCore
import Foundation

public enum SidebarPins {
  public static func canPin(_ item: WorkspaceSidebarItem) -> Bool {
    !QuietChildren.isQuiet(item)
  }

  public static func pinnedIDs(_ pinnedIDs: [String], in items: [WorkspaceSidebarItem]) -> Set<String> {
    let unpinnable = items.filter { !canPin($0) }.map(\.id.uuidString)
    return Set(pinnedIDs).subtracting(unpinnable)
  }
}
