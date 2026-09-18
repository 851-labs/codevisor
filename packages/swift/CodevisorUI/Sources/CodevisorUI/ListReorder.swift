import CoreGraphics

/// Geometry for drag-to-reorder in a vertical list whose rows reflow live
/// under the drag.
///
/// The dragged row's ghost is compared against the OTHER rows' vertical
/// midpoints: it belongs after every row whose midpoint it has passed. The
/// rule is self-consistent across a reflow — once a row is displaced, its
/// new midpoint sits on the far side of the ghost — so variable-height rows
/// never oscillate between two slots.
public enum ListReorder {
  /// The index in `order` at which `draggingID` belongs when its ghost's
  /// vertical center is at `midY`. Nil when the id is absent or any other
  /// row has not reported a frame yet (an incomplete picture must not move
  /// anything).
  public static func destinationIndex<ID: Hashable>(
    of draggingID: ID,
    in order: [ID],
    frames: [ID: CGRect],
    midY: CGFloat
  ) -> Int? {
    guard order.contains(draggingID) else { return nil }
    var index = 0
    for id in order where id != draggingID {
      guard let frame = frames[id] else { return nil }
      if frame.midY < midY { index += 1 }
    }
    return index
  }

  /// `order` with `id` moved to `index`; unchanged when it is already there.
  public static func moving<ID: Hashable>(_ id: ID, to index: Int, in order: [ID]) -> [ID] {
    guard let current = order.firstIndex(of: id), current != index,
      (0..<order.count).contains(index)
    else { return order }
    var result = order
    result.remove(at: current)
    result.insert(id, at: index)
    return result
  }
}
