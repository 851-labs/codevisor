public enum SidebarRestore<Item: Hashable>: Hashable {
  case select(Item?)
  case wait

  public static func first(
    of candidates: [Item], orElse fallback: Item?, availability: (Item) -> SidebarItemAvailability
  ) -> Self {
    for candidate in candidates {
      switch availability(candidate) {
      case .available: return .select(candidate)
      case .pending: return .wait
      case .gone: continue
      }
    }
    return .select(fallback)
  }
}
