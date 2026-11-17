final class ConstantSidebarSelection: SidebarSelectionOwner {
  private let value: SidebarSelection?

  init(_ value: SidebarSelection?) {
    self.value = value
  }

  var selection: SidebarSelection? {
    get { value }
    set {}
  }
}
