import Foundation

public enum SplitTreeVisibility {
  public static func visible(_ tree: SplitNode, hiding hidden: Set<UUID>) -> SplitNode? {
    hidden.reduce(Optional(tree)) { remaining, id in remaining?.removingGroup(id: id) }
  }

  public static func restoring(_ hidden: Set<UUID>, in full: SplitNode, from visible: SplitNode) -> SplitNode {
    guard case let .split(orientation, children) = full else { return visible }

    let shown = children.indices.filter { Self.visible(children[$0].node, hiding: hidden) != nil }
    if shown.count == 1 {
      return replacingChild(shown[0], of: full, with: restoring(hidden, in: children[shown[0]].node, from: visible))
    }

    guard case let .split(_, visibleChildren) = visible, visibleChildren.count == shown.count else { return full }
    let shownShare = shown.map { children[$0].fraction }.reduce(0, +)
    var restored = children
    for (index, visibleChild) in zip(shown, visibleChildren) {
      restored[index] = SplitChild(
        fraction: visibleChild.fraction * shownShare,
        node: restoring(hidden, in: children[index].node, from: visibleChild.node)
      )
    }
    return .split(orientation: orientation, children: restored)
  }

  private static func replacingChild(_ index: Int, of split: SplitNode, with node: SplitNode) -> SplitNode {
    guard case let .split(orientation, children) = split else { return split }

    var updated = children
    updated[index].node = node
    return .split(orientation: orientation, children: updated)
  }
}
