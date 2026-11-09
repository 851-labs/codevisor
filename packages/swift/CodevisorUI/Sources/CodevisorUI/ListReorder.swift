import CoreGraphics

public enum ListReorder {
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

  public static func moving<ID: Hashable>(_ id: ID, to index: Int, in order: [ID]) -> [ID] {
    guard let current = order.firstIndex(of: id), current != index,
      (0..<order.count).contains(index)
    else { return order }
    var result = order
    result.remove(at: current)
    result.insert(id, at: index)
    return result
  }

  public static func moving<ID: Hashable>(_ id: ID, to index: Int, within subset: [ID], in order: [ID]) -> [ID] {
    let members = Set(subset)
    var regrouped = moving(id, to: index, in: order.filter(members.contains)).makeIterator()
    return order.map { members.contains($0) ? regrouped.next() ?? $0 : $0 }
  }

  public static func placing<ID: Hashable>(_ id: ID, at index: Int, among siblings: [ID], in order: [ID]) -> [ID] {
    guard order.contains(id), siblings.firstIndex(of: id) != index else { return order }

    var result = order.filter { $0 != id }
    let others = siblings.filter { $0 != id }
    guard let slot = slot(at: index, among: others, in: result) else { return order }

    result.insert(id, at: slot)
    return result
  }

  private static func slot<ID: Hashable>(at index: Int, among others: [ID], in order: [ID]) -> Int? {
    if others.indices.contains(index) { return order.firstIndex(of: others[index]) }
    guard index == others.count, let last = others.last else { return nil }

    return order.firstIndex(of: last).map { $0 + 1 }
  }
}
