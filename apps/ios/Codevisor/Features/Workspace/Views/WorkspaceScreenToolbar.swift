import SwiftUI

/// The live sheet's controls become the conversation controls during send.
struct WorkspaceScreenToolbar: ToolbarContent {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isNewChatPresentation: Bool
  let isPromotingNewChat: Bool
  let blocksServerContent: Bool
  let isDraft: Bool
  let onDismissNewChat: () -> Void
  let onAddTab: () -> Void

  var body: some ToolbarContent {
    if isNewChatPresentation && isPromotingNewChat {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: onDismissNewChat) {
          Image(systemName: "chevron.left")
        }
        .accessibilityLabel("Back")
        .allowsHitTesting(false)
      }
    }
    ToolbarItem(placement: .topBarTrailing) {
      if isNewChatPresentation {
        Button {
          onDismissNewChat()
        } label: {
          Image(systemName: isPromotingNewChat ? "plus" : "xmark")
            .contentTransition(.symbolEffect(.replace.magic(fallback: .offUp)))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: isPromotingNewChat)
        }
        .accessibilityLabel(isPromotingNewChat ? "New tab" : "Cancel")
        .allowsHitTesting(!isPromotingNewChat)
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
