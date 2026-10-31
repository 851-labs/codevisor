import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
  private var settingsPlacement: ToolbarItemPlacement {
    barsAreVertical ? .bottomBar : .topBarLeading
  }

  @ToolbarContentBuilder
  var homeSidebarToolbar: some ToolbarContent {
    ToolbarItem(placement: settingsPlacement) { settingsButton }
    if !failedSyncMachines.isEmpty {
      ToolbarItem(placement: settingsPlacement) {
        machineConnectionWarningButton
      }
    }
    if hasRemoteMachines || showsSampleSidebar {
      ToolbarItem(placement: .topBarTrailing) {
        HomeSidebarOptionsMenu(
          sections: environment.workspaceSections.sections, actions: sidebarActions,
          managesSections: !showsSampleSidebar)
      }
    }
    if hasRemoteMachines && showsSidebarModes {
      ToolbarItem(placement: .principal) { SidebarModePicker(mode: sidebarMode) }
      if showsSyncIndicator {
        ToolbarItem(placement: settingsPlacement) { syncSpinner }
      }
    } else if showsSyncIndicator {
      ToolbarItem(placement: .principal) {
        HomeSyncIndicatorLabel(text: syncIndicator.label ?? "Syncing…")
      }
    }
  }

  private var showsSyncIndicator: Bool {
    syncIndicator.isSyncing && failedSyncMachines.isEmpty
  }

  private var syncSpinner: some View {
    ProgressView()
      .controlSize(.small)
      .accessibilityLabel(syncIndicator.label ?? "Syncing…")
  }

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

  @ToolbarContentBuilder
  var sidebarNewChatToolbarItems: some ToolbarContent {
    if #available(iOS 27.0, *), showsNewChatButton {
      ToolbarSpacer(.flexible, placement: .bottomBar)
      ToolbarItem(placement: .bottomBar) { newChatButton }
    }
  }

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
