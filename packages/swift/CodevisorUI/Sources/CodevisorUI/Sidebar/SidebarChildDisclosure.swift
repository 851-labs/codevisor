import CodevisorCore
import Foundation

public struct SidebarChildDisclosure: Equatable, Sendable {
  public static let expandedPreferenceKey = "sidebar.expandedChildren"

  private let collapsed: Set<String>
  private let expanded: Set<String>

  public init(collapsed: [String], expanded: [String]) {
    self.collapsed = Set(collapsed)
    self.expanded = Set(expanded)
  }

  @MainActor
  public static func current(_ preferences: ClientPreferences = .shared) -> SidebarChildDisclosure {
    SidebarChildDisclosure(
      collapsed: preferences.value(forKey: SidebarGrouping.collapsedPreferenceKey, default: []),
      expanded: preferences.value(forKey: expandedPreferenceKey, default: []))
  }

  @MainActor
  public static func choose(_ isExpanded: Bool, for parentId: UUID, in preferences: ClientPreferences = .shared) {
    let key = isExpanded ? expandedPreferenceKey : SidebarGrouping.collapsedPreferenceKey
    forget(parentId, in: preferences)
    preferences.set(
      preferences.value(forKey: key, default: [String]()) + [SidebarRows.childrenGroupID(parentId)], forKey: key)
  }

  @MainActor
  public static func forget(_ parentId: UUID, in preferences: ClientPreferences = .shared) {
    let id = SidebarRows.childrenGroupID(parentId)
    for key in [SidebarGrouping.collapsedPreferenceKey, expandedPreferenceKey] {
      let ids = preferences.value(forKey: key, default: [String]())
      guard ids.contains(id) else { continue }
      preferences.set(ids.filter { $0 != id }, forKey: key)
    }
  }

  public static func startsCollapsed(_ children: [WorkspaceSidebarItem]) -> Bool {
    let newest = children.max { lhs, rhs in linkedAt(lhs) < linkedAt(rhs) }
    return newest?.parent?.isAgentMade == true
  }

  public func isExpanded(_ parentId: UUID, startsCollapsed: Bool) -> Bool {
    let id = SidebarRows.childrenGroupID(parentId)
    if collapsed.contains(id) { return false }
    if expanded.contains(id) { return true }
    return !startsCollapsed
  }

  public func isExpanded(_ parentId: UUID, in tree: SidebarWorkspaceTree) -> Bool {
    isExpanded(parentId, startsCollapsed: Self.startsCollapsed(tree.children[parentId] ?? []))
  }

  public func collapsedGroupIDs(in tree: SidebarWorkspaceTree) -> Set<String> {
    let startCollapsed = tree.children.keys.filter { !isExpanded($0, in: tree) }
    return collapsed.union(startCollapsed.map(SidebarRows.childrenGroupID))
  }

  private static func linkedAt(_ item: WorkspaceSidebarItem) -> Date {
    item.parent?.linkedAt ?? .distantPast
  }
}
