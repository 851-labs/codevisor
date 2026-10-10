import Foundation

/// Inserts a leaf without changing existing group identities or pane state.
enum SplitTreeInsertion {
  static func split(
    _ node: SplitNode,
    targetId: UUID, edge: SplitEdge, newGroupId: UUID, newGroupState: PaneGroupState
  ) -> SplitNode {
    switch node {
    case let .group(id, state):
      guard id == targetId else { return node }
      return splitLeaf(id: id, state: state, edge: edge, newGroupId: newGroupId, newGroupState: newGroupState)
    case let .split(orientation, children):
      if let inserted = insertingSibling(
        orientation: orientation, children: children, targetId: targetId,
        edge: edge, newGroupId: newGroupId, newGroupState: newGroupState
      ) {
        return inserted
      }
      return .split(
        orientation: orientation,
        children: children.map {
          SplitChild(
            fraction: $0.fraction,
            node: split(
              $0.node, targetId: targetId, edge: edge,
              newGroupId: newGroupId, newGroupState: newGroupState
            )
          )
        })
    }
  }

  private static func splitLeaf(
    id: UUID, state: PaneGroupState, edge: SplitEdge,
    newGroupId: UUID, newGroupState: PaneGroupState
  ) -> SplitNode {
    let target = SplitChild(fraction: 0.5, node: .group(id: id, state: state))
    let added = SplitChild(fraction: 0.5, node: .group(id: newGroupId, state: newGroupState))
    let children = edge.insertsBefore ? [added, target] : [target, added]
    return .split(orientation: edge.orientation, children: children)
  }

  private static func insertingSibling(
    orientation: SplitOrientation, children: [SplitChild], targetId: UUID,
    edge: SplitEdge, newGroupId: UUID, newGroupState: PaneGroupState
  ) -> SplitNode? {
    // Same-orientation parent: insert as a sibling, halving the
    // target child's share, instead of nesting another split.
    guard orientation == edge.orientation,
      let index = children.firstIndex(where: {
        if case let .group(id, _) = $0.node { return id == targetId }
        return false
      })
    else { return nil }
    var updated = children
    let share = updated[index].fraction / 2
    updated[index].fraction = share
    let added = SplitChild(fraction: share, node: .group(id: newGroupId, state: newGroupState))
    updated.insert(added, at: edge.insertsBefore ? index : index + 1)
    return .split(orientation: orientation, children: updated)
  }
}
