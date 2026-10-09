import CodevisorClient
import Foundation

/// Moving agents, folders and projects within the sidebar, as a list's
/// reorder asks: an item lands at an index among the items sharing its
/// level, and gets a position between its new neighbors' so every device
/// sorts it the same.
extension NavigationStore {
  /// Puts a top-level agent at `index` among `siblings`, the agents it is
  /// listed with, in order, itself excluded. Its folder doesn't change.
  public func moveAgent(_ id: UUID, to index: Int, among siblings: [UUID]) {
    guard let workspace = projection.workspacesById[id] else { return }
    let positions = siblings.map { projection.workspacesById[$0]?.effectiveSidebarPosition }
    guard let (lower, upper) = Self.neighbors(at: index, in: positions),
      let position = WorkspacePosition.between(lower, upper, id: id)
    else { return }
    enqueue(
      .reorderWorkspace(workspaceId: id, position: position, expectedRevision: workspace.sidebarOrderRevision),
      machineId: workspace.serverId)
  }

  /// Puts an agent nested under another at `index` among `siblings`, the
  /// other agents nested there, in order, itself excluded. Siblings that
  /// were never placed, or share a place, get distinct positions first, in
  /// their listed order.
  public func moveNestedAgent(_ id: UUID, to index: Int, among siblings: [UUID]) {
    guard let workspace = projection.workspacesById[id] else { return }
    var positions = siblings.map { projection.workspacesById[$0]?.parentTabPosition }
    let ascending = zip(positions, positions.dropFirst()).allSatisfy { lower, upper in
      guard let lower, let upper else { return false }
      return lower < upper
    }
    if positions.contains(nil) || !ascending {
      var previous: String?
      for (offset, sibling) in siblings.enumerated() {
        guard let position = WorkspacePosition.between(previous, nil, id: sibling) else { return }
        setGroupPosition(position, of: sibling)
        positions[offset] = position
        previous = position
      }
    }
    guard let (lower, upper) = Self.neighbors(at: index, in: positions),
      let position = WorkspacePosition.between(lower, upper, id: id)
    else { return }
    setGroupPosition(position, of: workspace.id)
  }

  /// Puts a folder at `index` among the other folders.
  public func moveFolder(_ id: UUID, to index: Int) {
    let others = folders.filter { UUID(uuidString: $0.id) != id }
    guard let folder = folders.first(where: { UUID(uuidString: $0.id) == id }),
      let (lower, upper) = Self.neighbors(at: index, in: others.map(\.position)),
      let position = WorkspacePosition.between(lower, upper, id: id)
    else { return }
    saveFolder(id: id, name: folder.name, position: position, collapsed: folder.collapsed)
  }

  /// Puts a project at `index` in `projects`, the order they're listed in.
  /// Every project's place is written, so all devices sort them alike.
  public func moveProject(_ id: UUID, to index: Int, among projects: [UUID]) {
    var order = projects.filter { $0 != id }
    order.insert(id, at: min(max(0, index), order.count))
    for (offset, project) in order.enumerated() {
      setSetting(
        Self.projectOrderKeyPrefix + project.uuidString.lowercased(),
        value: String(format: "%08d", (offset + 1) * 1024))
    }
  }

  private func setGroupPosition(_ position: String, of id: UUID) {
    guard let workspace = projection.workspacesById[id] else { return }
    enqueue(
      .updateWorkspaceHierarchy(workspaceId: id, change: .groupPosition(position)), machineId: workspace.serverId)
  }

  /// The positions an item inserted at `index` falls between; nil when a
  /// neighbor has none to compare against.
  static func neighbors(at index: Int, in positions: [String?]) -> (String?, String?)? {
    let index = min(max(0, index), positions.count)
    let lower = index > 0 ? positions[index - 1] : nil
    let upper = index < positions.count ? positions[index] : nil
    if index > 0, lower == nil { return nil }
    if index < positions.count, upper == nil { return nil }
    return (lower, upper)
  }
}
