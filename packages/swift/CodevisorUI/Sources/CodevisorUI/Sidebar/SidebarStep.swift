public enum SidebarStep {
  public static func target<Item>(in items: [Item], from current: Int?, by offset: Int) -> Item? {
    guard let current else { return entry(into: items, by: offset) }

    let target = current + offset
    guard target != current, items.indices.contains(target) else { return nil }
    return items[target]
  }

  public static func target<Row, Stop>(
    among rows: [Row], isCurrent: (Row) -> Bool, by offset: Int, stop: (Row) -> Stop?
  ) -> Stop? {
    guard offset != 0 else { return nil }

    let step = offset < 0 ? -1 : 1
    let current = rows.firstIndex(where: isCurrent).flatMap { stop(rows[$0]) == nil ? nil : $0 }
    var index = current.map { $0 + step } ?? (offset < 0 ? rows.count - 1 : 0)
    var remaining = current == nil ? 1 : abs(offset)
    while rows.indices.contains(index) {
      if let found = stop(rows[index]) {
        remaining -= 1
        if remaining == 0 { return found }
      }
      index += step
    }
    return nil
  }

  private static func entry<Item>(into items: [Item], by offset: Int) -> Item? {
    offset < 0 ? items.last : items.first
  }
}
