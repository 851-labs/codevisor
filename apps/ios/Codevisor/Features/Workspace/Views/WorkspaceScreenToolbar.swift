import SwiftUI

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
    if #available(iOS 27.0, *) {
      primaryAction.visibilityPriority(.high)
    } else {
      primaryAction
    }
  }

  private var primaryAction: some ToolbarContent {
    ToolbarItem(id: "workspace-primary-action", placement: .topBarTrailing) {
      if isNewChatPresentation {
        Button {
          onDismissNewChat()
        } label: {
          Label {
            Text(showsConversationControls ? "New tab" : "Cancel")
          } icon: {
            Image(systemName: showsConversationControls ? "plus.square.on.square" : "xmark")
              .contentTransition(.symbolEffect(.replace.magic(fallback: .offUp)))
          }
        }
        .allowsHitTesting(!isPromotingNewChat)
        .onChange(of: isPromotingNewChat, initial: true) { _, isPromoting in
          withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            showsConversationControls = isPromoting
          }
        }
      } else if !blocksServerContent, !isDraft {
        Button {
          onAddTab()
        } label: {
          Label("New tab", systemImage: "plus.square.on.square")
        }
      }
    }
  }
}
