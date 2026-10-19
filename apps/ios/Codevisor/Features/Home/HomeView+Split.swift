import CodevisorCore
import CodevisorUI
import SwiftUI

extension HomeView {
  static let sidebarColumnMinWidth: CGFloat = 300
  static let sidebarColumnIdealWidth: CGFloat = 340
  static let sidebarColumnMaxWidth: CGFloat = 520

  var splitContainer: some View {
    NavigationSplitView(columnVisibility: $sidebarColumnVisibility) {
      homeRoot
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          homeSidebarToolbar
          sidebarNewChatToolbarItems
        }
        .overlay(alignment: .bottomTrailing) {
          sidebarNewChatOverlay
        }
        .navigationSplitViewColumnWidth(
          min: Self.sidebarColumnMinWidth,
          ideal: Self.sidebarColumnIdealWidth,
          max: Self.sidebarColumnMaxWidth
        )
    } detail: {
      NavigationStack(path: $detailPath) {
        splitDetail
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.frame(in: .global).minX
      } action: { minX in
        detailLeadingInset = minX
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      restoreAutoCollapsedSidebarIfWidened(to: width)
    }
  }

  func dismissOverlaySidebarAfterSelection() {
    guard detailLeadingInset < 1, sidebarColumnVisibility != .detailOnly else { return }
    withAnimation(.smooth(duration: 0.3)) {
      sidebarColumnVisibility = .detailOnly
    }
    sidebarAutoCollapsed = true
    IOSNavigationDiagnostics.record("home.sidebar.overlayDismissed")
  }

  func restoreAutoCollapsedSidebarIfWidened(to width: CGFloat) {
    defer { splitContainerWidth = width }
    guard sidebarAutoCollapsed, splitContainerWidth > 0, width > splitContainerWidth + 1 else { return }
    sidebarAutoCollapsed = false
    sidebarColumnVisibility = .doubleColumn
    IOSNavigationDiagnostics.record("home.sidebar.restored", "width=\(Int(width))")
  }

  @ViewBuilder
  var splitDetail: some View {
    if !hasRemoteMachines && !showsSampleSidebar {
      ChatSurfaceBackground()
        .ignoresSafeArea()
    } else {
      detailScreen(for: navigation.detailRoute(fallbackServerId: nil))
        .id(navigation.detailIdentity(promotedDraftSessionId: promotedDraftSessionId, draftGeneration: draftGeneration))
    }
  }

  @ViewBuilder
  func detailScreen(for route: HomeRoute) -> some View {
    if case let .bot(serverId, botId) = route {
      BotConversationScreen(serverId: serverId, botId: botId, onDeleted: closeBot, onNewTab: openNewTab(forBot:))
    } else {
      workspaceDetailScreen(for: route)
    }
  }

  private func workspaceDetailScreen(for route: HomeRoute) -> some View {
    let parameters = HomeDetailParameters(route: route, projectList: projectList)
    return WorkspaceScreen(
      sessionId: parameters.sessionId,
      serverId: parameters.serverId,
      workspaceId: parameters.workspaceId,
      preferredChatSessionId: parameters.preferredChatSessionId,
      preferredPaneId: parameters.preferredPaneId,
      preferredLeafId: parameters.preferredLeafId,
      onSelectedPaneChanged: followWorkspacePaneSelection,
      initialController: parameters.initialController,
      initialComposerFocusRequest: parameters.isDraft ? detailComposerFocusRequest : nil,
      onInitialComposerFocusRequestFulfilled: consumeDetailFocusRequest,
      onDraftStarted: handleDraftStarted,
      onWorkspaceReady: markPromotedWorkspaceReady,
      transcriptPresentationRole: .foreground,
      onSendAnimationCompleted: { _ in commitPendingDraftPromotion(reason: "sendAnimation") }
    )
  }

  func followWorkspacePaneSelection(_ selection: WorkspacePaneSelection) {
    guard layoutMode == .split,
      navigation.followPaneSelection(workspaceId: selection.workspaceId, paneId: selection.paneId)
    else { return }
    IOSNavigationDiagnostics.record(
      "home.followPaneSelection",
      "workspace=\(shortID(selection.workspaceId)) pane=\(shortID(selection.paneId))"
    )
  }

  func selectDetail(_ route: HomeRoute?) {
    if route?.isNewChat ?? true {
      promotedDraftSessionId = nil
      draftGeneration = UUID()
    }
    detailPath = NavigationPath()
    navigation.select(route)
  }
}

struct HomeDetailParameters {
  var sessionId: UUID?
  var serverId: String?
  var workspaceId: UUID?
  var preferredChatSessionId: UUID?
  var preferredPaneId: UUID?
  var preferredLeafId: UUID?
  var initialController: SessionController?
  var isDraft: Bool

  init(route: HomeRoute, projectList: ProjectListModel) {
    switch route {
    case let .newChat(serverId):
      self.serverId = serverId
      isDraft = true
    case let .workspace(
      serverId, workspaceId, anchorSessionId, preferredChatSessionId, preferredPaneId, preferredLeafId):
      sessionId = anchorSessionId
      self.serverId = serverId
      self.workspaceId = workspaceId
      self.preferredChatSessionId = preferredChatSessionId
      self.preferredPaneId = preferredPaneId
      self.preferredLeafId = preferredLeafId
      initialController = anchorSessionId.flatMap { projectList.session($0, serverId: serverId) }
        .flatMap { session in
          ChatControllerCache.shared.existingController(sessionId: session.id, serverId: serverId)
        }
      isDraft = false
    case let .bot(serverId, _):
      self.serverId = serverId
      isDraft = false
    }
  }
}
