import Observation

@Observable
final class LocalSidebarSelection: SidebarSelectionOwner {
  var selection: SidebarSelection?

  init(_ selection: SidebarSelection? = nil) {
    self.selection = selection
  }
}
