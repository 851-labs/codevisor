public enum SidebarCollapse {
  public static func shown<Item: Identifiable>(
    _ items: [Item], isExpanded: Bool, keeping selectedID: Item.ID?
  ) -> [Item] {
    isExpanded ? items : items.filter { $0.id == selectedID }
  }
}
