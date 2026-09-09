import SwiftUI

/// The workspace nav-bar controls. The New Chat sheet keeps its compose
/// chrome (title, ×) for its whole life — a first send changes the content
/// under it, and the sheet's expansion into the route morphs the chrome
/// into the route's, the way iMessage's compose bar becomes the
/// conversation bar as the sheet grows.
struct WorkspaceScreenToolbar: ToolbarContent {
  let isNewChatPresentation: Bool
  let blocksServerContent: Bool
  let isDraft: Bool
  let onDismissNewChat: () -> Void
  let onAddTab: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
      if isNewChatPresentation {
        Button {
          onDismissNewChat()
        } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Cancel")
        // Tabs belong to a workspace; an unsent draft has none yet.
      } else if !blocksServerContent, !isDraft {
        Button {
          onAddTab()
        } label: {
          Image(systemName: "plus")
        }
        .accessibilityLabel("New tab")
      }
    }
  }
}
