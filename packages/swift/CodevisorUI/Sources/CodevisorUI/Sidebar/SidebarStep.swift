public enum SidebarStep {
  public static func target<Item>(in items: [Item], from current: Int?, by offset: Int) -> Item? {
    target(among: Array(items.enumerated()), isCurrent: { $0.offset == current }, by: offset) { $0.element }
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
}
