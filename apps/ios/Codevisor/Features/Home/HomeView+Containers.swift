import CodevisorCore
import CodevisorUI
import SwiftUI

/// Home's compact-width container: the authoritative navigation stack that
/// pushes workspaces over the sidebar list and hosts the New Chat sheet.
/// Nothing about this presentation changes for iPhone Duo; the unfolded
/// display uses `splitContainer` instead.
extension HomeView {
  /// The sidebar content shared by both containers, reading the bar edge
  /// of whichever container hosts it.
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
      noMachineState
    } else {
      refreshableNavigationContent
    }
  }

  var stackContainer: some View {
    NavigationStack(path: $navigation.path) {
      homeRoot
        // No title: the workspace headers are the page's headings, and the
        // bar keeps only its two buttons. The pushed workspace's back button
        // falls back to the system "Back" label.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          homeSidebarToolbar
          newChatToolbarItems
        }
        .navigationDestination(for: HomeRoute.self) { route in
          stackDestination(route)
        }
        // The New Chat sheet is a compact-width presentation; its zoom
        // transition sources from the bottom-bar button above.
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
      // Reached only by folding while the New Chat page was the split
      // detail: the draft continues as a pushed page with the system back.
      draftDestination(serverId: serverId)
    }
  }
}
