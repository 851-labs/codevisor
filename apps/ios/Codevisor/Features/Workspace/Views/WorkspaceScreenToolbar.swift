import SwiftUI

/// The workspace nav-bar controls: New Chat chrome on the leading edge,
/// cancel / new-tab on the trailing edge. Tab switching lives in the sidebar.
struct WorkspaceScreenToolbar: ToolbarContent {
  let isNewChatPresentation: Bool
  let hasStarted: Bool
  let isFirstSendPromotionSurface: Bool
  let blocksServerContent: Bool
  let isDraft: Bool
  let onDismissNewChat: () -> Void
  let onAddTab: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      if isNewChatPresentation,
        hasStarted || isFirstSendPromotionSurface
      {
        Button {
          onDismissNewChat()
        } label: {
          Image(systemName: "chevron.left")
        }
        .accessibilityLabel("Agents")
      }
    }
    ToolbarItem(placement: .topBarTrailing) {
      if isNewChatPresentation, !hasStarted, !isFirstSendPromotionSurface {
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
