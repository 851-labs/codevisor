import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
  var homeRoot: some View {
    homeRootContent
      .background {
        VerticalBarEdgeReader { isVertical in
          guard barsAreVertical != isVertical else { return }
          barsAreVertical = isVertical
          IOSNavigationDiagnostics.record("home.barsVertical", "value=\(isVertical)")
        }
      }
  }

  @ViewBuilder
  private var homeRootContent: some View {
    if showsSampleSidebar {
      #if DEBUG
        sampleSidebar
      #endif
    } else if !hasRemoteMachines {
      if environment.navigationRosterStatus == .unverified {
        refreshableState(allowsStateHitTesting: false) {
          HomeNavigationSyncView(state: .loading(machineName: "your machines"))
        }
      } else {
        noMachineState
      }
    } else {
      refreshableNavigationContent
    }
  }

  var stackContainer: some View {
    NavigationStack(path: $navigation.path) {
      homeRoot
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          homeSidebarToolbar
          newChatToolbarItems
        }
        .navigationDestination(for: HomeRoute.self) { route in
          stackDestination(route)
        }
        .sheet(item: $presentedNewChatFlow, onDismiss: handleNewChatSheetDismissed) {
          flow in
          newChatSheet(flow)
        }
    }
  }

  @ViewBuilder
  func stackDestination(_ route: HomeRoute) -> some View {
    switch route {
    case let .workspace(
      serverId,
      workspaceId,
      anchorSessionId,
      preferredChatSessionId,
      preferredPaneId,
      preferredLeafId
    ):
      workspaceDestination(
        serverId: serverId,
        workspaceId: workspaceId,
        anchorSessionId: anchorSessionId,
        preferredChatSessionId: preferredChatSessionId,
        preferredPaneId: preferredPaneId,
        preferredLeafId: preferredLeafId
      )
    case let .newChat(serverId):
      draftDestination(serverId: serverId)
    case let .bot(serverId, botId):
      BotConversationScreen(serverId: serverId, botId: botId, onDeleted: closeBot)
    }
  }
}
