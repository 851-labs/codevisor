import CodevisorCore
import Foundation

public struct SidebarWorkspaceTree: Equatable {
  public let roots: [WorkspaceSidebarItem]
  public let children: [UUID: [WorkspaceSidebarItem]]
  private let parents: [UUID: UUID]

  public init(_ items: [WorkspaceSidebarItem], pinnedIDs: [String]) {
    let pinned = Set(pinnedIDs)
    let listed = Set(items.map(\.id))
    var parents: [UUID: UUID] = [:]
    for item in items {
      guard let parent = item.parentWorkspaceId, parent != item.id, listed.contains(parent),
        !pinned.contains(item.id.uuidString) || pinned.contains(parent.uuidString)
      else { continue }
      parents[item.id] = parent
    }
    func isInCycle(_ id: UUID) -> Bool {
      var seen: Set<UUID> = []
      var current = parents[id]
      while let next = current, seen.insert(next).inserted {
        if next == id { return true }
        current = parents[next]
      }
      return false
    }
    let cyclic = Set(parents.keys.filter(isInCycle))
    var roots: [WorkspaceSidebarItem] = []
    var children: [UUID: [WorkspaceSidebarItem]] = [:]
    var nestedParents: [UUID: UUID] = [:]
    for item in items {
      if let parent = parents[item.id], !cyclic.contains(item.id) {
        children[parent, default: []].append(item)
        nestedParents[item.id] = parent
      } else {
        roots.append(item)
      }
    }
    self.roots = roots
    self.children = children
    self.parents = nestedParents
  }

  public func root(of id: UUID) -> UUID {
    guard let parent = parents[id] else { return id }
    return root(of: parent)
  }

  public func parent(of id: UUID) -> UUID? {
    parents[id]
  }
}
