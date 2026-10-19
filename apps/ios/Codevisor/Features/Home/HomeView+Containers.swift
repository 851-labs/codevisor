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
    .environment(\.hostedBotHeaderHeight, botHeaderHeight)
    .overlay(alignment: .top) { stackBotHeader }
  }

  @ViewBuilder
  private var stackBotHeader: some View {
    Group {
      if case let .bot(serverId, botId)? = path.last,
        let bot = environment.bots.bot(serverId: serverId, id: botId)
      {
        BotConversationHeader(bot: bot) { botEditor = .edit(bot) }
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            botHeaderHeight = $0
          }
          .transition(.opacity)
      }
    }
    .animation(Motion.quick(reduceMotion: reduceMotion), value: path.last)
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
      BotConversationScreen(
        serverId: serverId, botId: botId, showsHeader: false,
        onOpenDetails: { botEditor = .edit($0) }, onNewTab: openNewTab(forBot:))
    }
  }
}
