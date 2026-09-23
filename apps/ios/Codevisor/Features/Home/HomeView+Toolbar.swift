import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Toolbar

extension HomeView {
  /// Where Home's settings affordances sit. A horizontal bar keeps them at
  /// the top leading edge; iPhone Duo's side strip puts them at its foot,
  /// below the compose action.
  private var settingsPlacement: ToolbarItemPlacement {
    barsAreVertical ? .bottomBar : .topBarLeading
  }

  /// Home is the fleet's, so there is no machine switcher — selection
  /// follows the chat you open, and machines are managed in Settings.
  @ToolbarContentBuilder
  var homeSidebarToolbar: some ToolbarContent {
    ToolbarItem(placement: settingsPlacement) { settingsButton }
    if !failedSyncMachines.isEmpty {
      ToolbarItem(placement: settingsPlacement) {
        machineConnectionWarningButton
      }
    }
  }

  /// The compose button on the compact stack: bottom trailing on a
  /// horizontal bar, and the head of iPhone Duo's side strip.
  @ToolbarContentBuilder
  var newChatToolbarItems: some ToolbarContent {
    if showsNewChatButton {
      if barsAreVertical {
        newChatItem(placement: .topBarTrailing)
      } else {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        newChatItem(placement: .bottomBar)
      }
    }
  }

  /// The split layout's compose action lives only in the sidebar, at its
  /// bottom trailing corner, accent-tinted — out of the detail's bars in
  /// every pose. On the New Chat page a tap just refocuses the composer.
  ///
  /// iOS 27 draws it as a real Liquid Glass bar item. iPadOS 26 cannot:
  /// a split sidebar's `.bottomBar` renders the item but discards the
  /// button style's background, leaving a white glyph on a white sidebar,
  /// and `.topBarTrailing` crashes outright. So 26 alone falls back to
  /// `sidebarNewChatOverlay`, which draws the capsule itself.
  @ToolbarContentBuilder
  var sidebarNewChatToolbarItems: some ToolbarContent {
    if #available(iOS 27.0, *), showsNewChatButton {
      ToolbarSpacer(.flexible, placement: .bottomBar)
      ToolbarItem(placement: .bottomBar) { newChatButton }
    }
  }

  /// The iPadOS 26 stand-in for the bar item above: the same accent-tinted
  /// compose affordance in the same corner, drawn by hand because no
  /// toolbar placement renders it correctly on that release.
  @ViewBuilder
  var sidebarNewChatOverlay: some View {
    if #unavailable(iOS 27.0), showsNewChatButton {
      Button {
        presentNewChat()
      } label: {
        Image(systemName: "square.and.pencil")
          .font(.title3)
          .foregroundStyle(.white)
          .padding(13)
          .background(Circle().fill(Color.accentColor))
          .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("New chat")
      .padding([.trailing, .bottom], 16)
    }
  }

  /// On iPhone Duo's strip items overflow from the bottom up, so the
  /// compose action carries a high visibility priority and a title for
  /// the overflow menu.
  @ToolbarContentBuilder
  private func newChatItem(placement: ToolbarItemPlacement) -> some ToolbarContent {
    if #available(iOS 27.0, *) {
      ToolbarItem(placement: placement) { newChatButton }
        .visibilityPriority(.high)
        .matchedTransitionSource(id: Self.newChatTransitionID, in: newChatTransition)
    } else {
      ToolbarItem(placement: placement) { newChatButton }
        .matchedTransitionSource(id: Self.newChatTransitionID, in: newChatTransition)
    }
  }

  /// The compose action, accent-tinted wherever it appears: the phone's
  /// bottom bar, iPhone Duo's folded strip, and the split sidebar.
  var newChatButton: some View {
    Button {
      presentNewChat()
    } label: {
      Label("New chat", systemImage: "square.and.pencil")
    }
    .buttonStyle(.glassProminent)
    .tint(.accentColor)
  }
}
