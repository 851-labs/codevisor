public struct SidebarRouteChange: Hashable, Sendable {
  public let remembers: SidebarMode?
  public let restores: SidebarMode?

  public init<Selection>(
    from old: SidebarRoute<Selection>, to new: SidebarRoute<Selection>, owner: (Selection) -> SidebarMode?
  ) {
    remembers = Self.owner(of: new, changedFrom: old, owner: owner)
    restores = Self.restoredMode(from: old, to: new)
  }

  private static func owner<Selection>(
    of new: SidebarRoute<Selection>, changedFrom old: SidebarRoute<Selection>, owner: (Selection) -> SidebarMode?
  ) -> SidebarMode? {
    guard new.selection != old.selection, let selection = new.selection else { return nil }

    return owner(selection) ?? unownedSelectionMode(in: new.mode)
  }

  private static func unownedSelectionMode(in mode: SidebarMode) -> SidebarMode? {
    mode == .code ? .code : nil
  }

  private static func restoredMode<Selection>(
    from old: SidebarRoute<Selection>, to new: SidebarRoute<Selection>
  )
    -> SidebarMode?
  {
    let isLaunch = old == new
    guard isLaunch || new.mode != old.mode else { return nil }

    return new.mode
  }
}
