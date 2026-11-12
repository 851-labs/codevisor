import CodevisorCore
import Foundation

public struct SidebarWorkspaceTree: Equatable {
  public let roots: [WorkspaceSidebarItem]
  public let children: [UUID: [WorkspaceSidebarItem]]
  private let parents: [UUID: UUID]

  public init(
    _ items: [WorkspaceSidebarItem], pinnedIDs: [String], hiddenParentIDs: Set<UUID> = [],
    revealing revealedID: UUID? = nil
  ) {
    let links = Self.parentLinks(items, pinnedIDs: SidebarPins.pinnedIDs(pinnedIDs, in: items))
    var hidden = Self.hiddenIDs(items, links: links, hiddenParentIDs: hiddenParentIDs)
    if let revealedID { hidden.remove(revealedID) }
    func shownAncestor(of id: UUID) -> UUID? {
      guard hidden.contains(id) else { return id }
      return links[id].flatMap(shownAncestor)
    }
    var roots: [WorkspaceSidebarItem] = []
    var children: [UUID: [WorkspaceSidebarItem]] = [:]
    for item in items where !hidden.contains(item.id) {
      if let parent = links[item.id].flatMap(shownAncestor) {
        children[parent, default: []].append(item)
      } else {
        roots.append(item)
      }
    }
    self.roots = roots
    self.children = children
    self.parents = links
  }

  public func root(of id: UUID) -> UUID {
    guard let parent = parents[id] else { return id }
    return root(of: parent)
  }

  public func parent(of id: UUID) -> UUID? {
    parents[id]
  }

  private static func hiddenIDs(
    _ items: [WorkspaceSidebarItem], links: [UUID: UUID], hiddenParentIDs: Set<UUID>
  ) -> Set<UUID> {
    func isHidden(_ item: WorkspaceSidebarItem) -> Bool {
      guard QuietChildren.isQuiet(item) else { return false }
      return links[item.id] != nil || item.parentWorkspaceId.map(hiddenParentIDs.contains) == true
    }
    return Set(items.filter(isHidden).map(\.id))
  }

  private static func parentLinks(_ items: [WorkspaceSidebarItem], pinnedIDs: Set<String>) -> [UUID: UUID] {
    let listed = Set(items.map(\.id))
    var parents: [UUID: UUID] = [:]
    for item in items {
      guard let parent = item.parentWorkspaceId, parent != item.id, listed.contains(parent),
        !pinnedIDs.contains(item.id.uuidString) || pinnedIDs.contains(parent.uuidString)
      else { continue }
      parents[item.id] = parent
    }
    return parents.filter { !isInCycle($0.key, parents: parents) }
  }

  private static func isInCycle(_ id: UUID, parents: [UUID: UUID]) -> Bool {
    var seen: Set<UUID> = []
    var current = parents[id]
    while let next = current, seen.insert(next).inserted {
      if next == id { return true }
      current = parents[next]
    }
    return false
  }
}
