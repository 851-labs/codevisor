import Foundation

extension WorkspaceTab {
  /// A historical device-local alias cannot hide the shared chat title.
  public func displayTitle(for pane: PaneDescriptorState?, chatTitle: String?) -> String {
    if pane?.kind == .chat { return chatTitle ?? pane?.name ?? "New Chat" }
    return customTitle ?? pane?.name ?? "New Tab"
  }
}
