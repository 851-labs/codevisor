import Foundation

extension WorkspaceTab {
  public func displayTitle(for pane: PaneDescriptorState?, chatTitle: String?) -> String {
    if pane?.kind == .chat { return chatTitle ?? pane?.name ?? "New Chat" }
    return customTitle ?? pane?.displayName ?? "New Tab"
  }
}
