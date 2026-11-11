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
        sidebarOptionsMenu
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

  @ViewBuilder
  private var sidebarOptionsMenu: some View {
    if sidebarMode.wrappedValue == .bots {
      HomeSidebarOptionsMenu(
        sections: environment.botSections.sections, actions: sidebarActions.botSections,
        managesSections: !showsSampleSidebar, showsGrouping: false)
    } else {
      HomeSidebarOptionsMenu(
        sections: environment.workspaceSections.sections, actions: sidebarActions.workspaceSections,
        managesSections: !showsSampleSidebar)
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
    if showsNewChatToolbarButton {
      if barsAreVertical {
        newChatItem(placement: .topBarTrailing)
      } else {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        newChatItem(placement: .bottomBar)
      }
    } else if showsNewBotToolbarButton {
      if barsAreVertical {
        ToolbarItem(placement: .topBarTrailing) { newBotButton }
      } else {
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { newBotButton }
      }
    }
  }

  @ToolbarContentBuilder
  var sidebarNewChatToolbarItems: some ToolbarContent {
    if #available(iOS 27.0, *), showsNewChatToolbarButton {
      ToolbarSpacer(.flexible, placement: .bottomBar)
      ToolbarItem(placement: .bottomBar) { newChatButton }
    } else if #available(iOS 27.0, *), showsNewBotToolbarButton {
      ToolbarSpacer(.flexible, placement: .bottomBar)
      ToolbarItem(placement: .bottomBar) { newBotButton }
    }
  }

  @ViewBuilder
  var sidebarNewChatOverlay: some View {
    if #unavailable(iOS 27.0), showsNewChatToolbarButton {
      HomeComposeOverlayButton(image: Image(systemName: "square.and.pencil"), label: "New chat") { presentNewChat() }
    } else if #unavailable(iOS 27.0), showsNewBotToolbarButton {
      HomeComposeOverlayButton(image: CodevisorSymbol.mascotBadgePlus.image, label: "New Bot") { botEditor = .create }
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

  var newBotButton: some View {
    Button {
      botEditor = .create
    } label: {
      Label("New Bot", symbol: .mascotBadgePlus)
    }
    .buttonStyle(.glassProminent)
    .tint(.accentColor)
    .accessibilityIdentifier("sidebar.newBot")
  }
}
