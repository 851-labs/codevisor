public enum SidebarStep {
  public static func target<Item>(in items: [Item], from current: Int?, by offset: Int) -> Item? {
    target(among: Array(items.enumerated()), isCurrent: { $0.offset == current }, by: offset) { $0.element }
  }

  public static func target<Row, Stop>(
    among rows: [Row], isCurrent: (Row) -> Bool, by offset: Int, stop: (Row) -> Stop?
  ) -> Stop? {
    guard offset != 0, !rows.isEmpty else { return nil }

    let step = offset < 0 ? -1 : 1
    let current = rows.firstIndex(where: isCurrent).flatMap { stop(rows[$0]) == nil ? nil : $0 }
    var index = current ?? (offset < 0 ? rows.count : -1)
    var remaining = current == nil ? 1 : abs(offset)
    for _ in 0..<(rows.count * remaining) {
      index = (index + step + rows.count) % rows.count
      guard let found = stop(rows[index]) else { continue }

      remaining -= 1
      if remaining == 0 { return index == current ? nil : found }
    }
    return nil
  }
}
