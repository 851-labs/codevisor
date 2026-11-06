public enum SidebarStep {
  public static func target<Item>(in items: [Item], from current: Int?, by offset: Int) -> Item? {
    guard let current else { return entry(into: items, by: offset) }

    let target = current + offset
    guard target != current, items.indices.contains(target) else { return nil }
    return items[target]
  }

  private static func entry<Item>(into items: [Item], by offset: Int) -> Item? {
    offset < 0 ? items.last : items.first
  }
}
