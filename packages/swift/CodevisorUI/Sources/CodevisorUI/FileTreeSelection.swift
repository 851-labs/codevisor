import Foundation

public struct FileTreeSelection: Equatable, Sendable {
  public private(set) var selected: Set<String> = []
  public private(set) var cursor: String?
  private var anchor: String?

  public init() {}

  public var single: String? {
    selected.count == 1 ? selected.first : nil
  }

  public func contains(_ id: String) -> Bool {
    selected.contains(id)
  }

  public func ordered(in order: [String]) -> [String] {
    order.filter(selected.contains)
  }

  public mutating func select(_ id: String) {
    selected = [id]
    cursor = id
    anchor = id
  }

  public mutating func toggle(_ id: String) {
    if selected.contains(id) {
      selected.remove(id)
    } else {
      selected.insert(id)
    }
    cursor = id
    anchor = id
  }

  public mutating func extend(to id: String, in order: [String]) {
    guard let start = order.firstIndex(of: anchor ?? id), let end = order.firstIndex(of: id) else {
      select(id)
      return
    }
    selected = Set(order[min(start, end)...max(start, end)])
    cursor = id
  }

  @discardableResult
  public mutating func move(by offset: Int, in order: [String], extending: Bool) -> String? {
    guard let next = Self.neighbor(of: cursor, by: offset, in: order) else { return nil }

    if extending {
      extend(to: next, in: order)
    } else {
      select(next)
    }
    return next
  }

  public mutating func selectAll(_ order: [String]) {
    selected = Set(order)
    anchor = order.first
    cursor = order.last
  }

  public mutating func clear() {
    self = FileTreeSelection()
  }

  public mutating func retain(_ order: [String]) {
    let visible = Set(order)
    selected.formIntersection(visible)
    if let cursor, !visible.contains(cursor) { self.cursor = nil }
    if let anchor, !visible.contains(anchor) { self.anchor = nil }
  }

  private static func neighbor(of cursor: String?, by offset: Int, in order: [String]) -> String? {
    guard !order.isEmpty else { return nil }
    guard let current = cursor.flatMap(order.firstIndex(of:)) else {
      return offset > 0 ? order.first : order.last
    }
    let next = current + offset
    return order.indices.contains(next) ? order[next] : nil
  }
}
