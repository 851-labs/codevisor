public struct SidebarRoute<Selection: Hashable>: Hashable {
  public var mode: SidebarMode
  public var selection: Selection?

  public init(mode: SidebarMode, selection: Selection?) {
    self.mode = mode
    self.selection = selection
  }
}
