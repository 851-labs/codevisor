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
  /// The decorative back chevron materializes at the top-left as the
  /// sheet's chrome becomes the conversation's. With iPhone Duo's vertical
  /// strip the real back button lives on the side, so the morph would
  /// appear in one place and land in another; skip it there.
  var showsBackMorph = true

  var body: some ToolbarContent {
    if isNewChatPresentation, showsBackMorph {
      ToolbarItem(id: "workspace-back", placement: .topBarLeading) {
        GlassEffectContainer {
          if showsConversationControls {
            Button(action: onDismissNewChat) {
              Label("Back", systemImage: "chevron.left")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .glassEffectID("workspace-back", in: glassNamespace)
            .glassEffectTransition(.materialize)
            .transition(.blurReplace)
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
    // The primary action stays visible when iPhone Duo's vertical strip
    // overflows; every item carries a title for the overflow menu.
    if #available(iOS 27.0, *) {
      primaryAction.visibilityPriority(.high)
    } else {
      primaryAction
    }
  }

  private var primaryAction: some ToolbarContent {
    ToolbarItem(id: "workspace-primary-action", placement: .topBarTrailing) {
      if isNewChatPresentation {
        // The chat it becomes has no button here; Cancel fades as it goes.
        Button("Cancel", systemImage: "xmark") {
          onDismissNewChat()
        }
        .opacity(showsConversationControls ? 0 : 1)
        .allowsHitTesting(!isPromotingNewChat)
        .onChange(of: isPromotingNewChat, initial: true) { _, isPromoting in
          // Animate only the toolbar's state. Animating the workspace's
          // promotion state also animates its keyboard avoidance layout.
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            showsConversationControls = isPromoting
          }
        }
      }
    }
  }
}
