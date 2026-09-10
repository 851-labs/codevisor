import SwiftUI

/// The live sheet's controls become the conversation controls during send.
struct WorkspaceScreenToolbar: ToolbarContent {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsConversationControls = false
  @Namespace private var glassNamespace
  let isNewChatPresentation: Bool
  let isPromotingNewChat: Bool
  let blocksServerContent: Bool
  let isDraft: Bool
  let onDismissNewChat: () -> Void
  let onAddTab: () -> Void

  var body: some ToolbarContent {
    if isNewChatPresentation {
      ToolbarItem(id: "workspace-back", placement: .topBarLeading) {
        GlassEffectContainer {
          if showsConversationControls {
            Button(action: onDismissNewChat) {
              Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("workspace-back", in: glassNamespace)
            .glassEffectTransition(.materialize)
            .transition(.blurReplace)
            .accessibilityLabel("Back")
          }
        }
        .frame(width: 44, height: 44)
        .animation(
          reduceMotion ? nil : .smooth(duration: 0.25).delay(0.1),
          value: showsConversationControls
        )
        .allowsHitTesting(false)
      }
      .sharedBackgroundVisibility(.hidden)
    }
    ToolbarItem(id: "workspace-primary-action", placement: .topBarTrailing) {
      if isNewChatPresentation {
        Button {
          onDismissNewChat()
        } label: {
          Image(systemName: showsConversationControls ? "plus" : "xmark")
            .contentTransition(.symbolEffect(.replace.magic(fallback: .offUp)))
        }
        .accessibilityLabel(showsConversationControls ? "New tab" : "Cancel")
        .allowsHitTesting(!isPromotingNewChat)
        .onChange(of: isPromotingNewChat, initial: true) { _, isPromoting in
          // Animate only the toolbar's state. Animating the workspace's
          // promotion state also animates its keyboard avoidance layout.
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            showsConversationControls = isPromoting
          }
        }
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
