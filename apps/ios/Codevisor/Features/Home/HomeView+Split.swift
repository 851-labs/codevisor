import CodevisorCore
import CodevisorUI
import SwiftUI

/// Home's regular-width containers, after Notes. On iPad, three columns:
/// the workspaces, the selected workspace's page, and its open tab. On the
/// unfolded iPhone Duo display, two: the workspaces beside a stack that
/// starts at the selected workspace's page and pushes its tabs, as the phone
/// does. With nothing selected the detail is a New Chat draft. The system
/// collapses a split to a stack on compact width, but Home swaps to
/// `stackContainer` instead so the compact experience stays byte-identical.
extension HomeView {
  static let sidebarColumnMinWidth: CGFloat = 300
  static let sidebarColumnIdealWidth: CGFloat = 340
  /// At least half the inner display, so the balanced split can align its
  /// divider with the fold when the device is held like a book.
  static let sidebarColumnMaxWidth: CGFloat = 520

  /// iPad has room for the page between the workspaces and the tab.
  static var splitHasContentColumn: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  /// Every column the split has, shown.
  static var splitColumnsShown: NavigationSplitViewVisibility {
    splitHasContentColumn ? .all : .doubleColumn
  }

  @ViewBuilder
  var splitContainer: some View {
    if Self.splitHasContentColumn {
      NavigationSplitView(columnVisibility: $sidebarColumnVisibility) {
        splitSidebar
      } content: {
        splitPage
          .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
      } detail: {
        NavigationStack(path: $detailPath) {
          splitDetail
        }
        .modifier(DetailInsetReader(inset: $detailLeadingInset))
      }
      .navigationSplitViewStyle(.balanced)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        restoreAutoCollapsedSidebarIfWidened(to: $0)
      }
    } else {
      NavigationSplitView(columnVisibility: $sidebarColumnVisibility) {
        splitSidebar
      } detail: {
        NavigationStack(path: pageStackPath) {
          pageStackRoot
            .navigationDestination(for: HomeRoute.self) { stackDestination($0) }
        }
        .modifier(DetailInsetReader(inset: $detailLeadingInset))
      }
      .navigationSplitViewStyle(.balanced)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        restoreAutoCollapsedSidebarIfWidened(to: $0)
      }
    }
  }

  private var splitSidebar: some View {
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
  }

  // MARK: iPad

  /// The middle column: the selected workspace's page, its open tab selected.
  @ViewBuilder
  private var splitPage: some View {
    if let workspace = navigation.selectedWorkspace {
      WorkspaceOutlineScreen(
        serverId: workspace.serverId, workspaceId: workspace.workspaceId, selectedTab: splitTabSelection
      )
      .id(workspace.workspaceId)
    } else if case let .folder(folderId) = navigation.path.first {
      WorkspaceFolderScreen(folderId: folderId)
        .id(folderId)
    } else {
      ContentUnavailableView("No Workspace Selected", systemImage: "square.stack")
    }
  }

  /// The page's selection: the pane the detail shows. Choosing a nested
  /// workspace selects it in the sidebar instead, as Notes does a folder.
  private var splitTabSelection: Binding<UUID?> {
    Binding(
      get: { shownPaneId },
      set: { id in
        guard let id, let shown = navigation.selectedWorkspace else { return }
        if let workspace = environment.workspaces.workspace(id: id) {
          openRoute(.agent(serverId: workspace.serverId, workspaceId: workspace.id))
          return
        }
        let chat = paneChatSessionId(id, in: shown.workspaceId)
        openRoute(
          .workspace(
            serverId: shown.serverId, workspaceId: shown.workspaceId, anchorSessionId: chat,
            preferredChatSessionId: chat, preferredPaneId: chat == nil ? id : nil))
        dismissOverlaySidebarAfterSelection()
      })
  }

  /// The pane the route names, else the one the workspace has selected.
  private var shownPaneId: UUID? {
    guard let shown = navigation.selectedWorkspace,
      let workspace = environment.workspaces.workspace(id: shown.workspaceId)
    else { return nil }
    let panes = workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
    let named = navigation.selectedPaneId { chat in panes.first { $0.chatSessionId == chat }?.id }
    if let named { return named }
    guard let tab = workspace.selectedCenterTab else { return nil }
    return tab.root.group(id: tab.activeLeafId)?.selectedPane?.id
  }

  private func paneChatSessionId(_ paneId: UUID, in workspaceId: UUID) -> UUID? {
    let workspace = environment.workspaces.workspace(id: workspaceId)
    let pane = workspace?.centerTabs.lazy.flatMap { $0.root.allGroups.flatMap(\.state.panes) }.first { $0.id == paneId }
    return pane?.kind == .chat ? pane?.chatSessionId : nil
  }

  // MARK: iPhone Duo

  /// The detail stack below its root: the tab pushed on the selected
  /// workspace's page.
  private var pageStackPath: Binding<[HomeRoute]> {
    Binding(
      get: { Array(navigation.path.dropFirst()) },
      set: { navigation.path = Array(navigation.path.prefix(1)) + $0 })
  }

  /// The selected workspace's page; or, when a tab or draft was opened
  /// directly, that screen, with the draft keeping its identity through its
  /// first send.
  @ViewBuilder
  private var pageStackRoot: some View {
    if case let .agent(serverId, workspaceId) = navigation.path.first {
      WorkspaceOutlineScreen(serverId: serverId, workspaceId: workspaceId)
        .id(workspaceId)
    } else if case let .folder(folderId) = navigation.path.first {
      WorkspaceFolderScreen(folderId: folderId)
        .id(folderId)
    } else {
      splitDetail
    }
  }

  /// A selection list in a split view highlights and swipes natively, but
  /// SwiftUI leaves an overlay sidebar open after a selection. Dismiss it
  /// here — only when it floats over the detail; a tiled sidebar stays.
  func dismissOverlaySidebarAfterSelection() {
    guard detailLeadingInset < 1, sidebarColumnVisibility != .detailOnly else { return }
    withAnimation(.smooth(duration: 0.3)) {
      sidebarColumnVisibility = .detailOnly
    }
    sidebarAutoCollapsed = true
    IOSNavigationDiagnostics.record("home.sidebar.overlayDismissed")
  }

  /// Widening after a dismissal (portrait to landscape) restores the tiled
  /// sidebar instead of leaving it hidden. Narrowing keeps it dismissed.
  func restoreAutoCollapsedSidebarIfWidened(to width: CGFloat) {
    defer { splitContainerWidth = width }
    guard sidebarAutoCollapsed, splitContainerWidth > 0, width > splitContainerWidth + 1 else { return }
    sidebarAutoCollapsed = false
    sidebarColumnVisibility = Self.splitColumnsShown
    IOSNavigationDiagnostics.record("home.sidebar.restored", "width=\(Int(width))")
  }

  @ViewBuilder
  var splitDetail: some View {
    // A folder's page has no tab to show beside it.
    if !hasRemoteMachines && !showsSampleSidebar || isFolderSelected {
      // The sidebar column carries the connect prompt; the detail stays a
      // quiet surface until a machine is paired.
      ChatSurfaceBackground()
        .ignoresSafeArea()
    } else {
      detailScreen(for: navigation.detailRoute(fallbackServerId: nil))
        // A draft keeps its identity through its first send so the
        // composer, transcript, and keyboard are not remounted.
        .id(detailIdentity)
    }
  }

  private var isFolderSelected: Bool {
    if case .folder = navigation.selection { true } else { false }
  }

  /// On iPad the detail is always a tab, so a workspace whose page alone is
  /// selected keeps its screen when one of its tabs is then chosen.
  private var detailIdentity: HomeDetailIdentity {
    let identity = navigation.detailIdentity(
      promotedDraftSessionId: promotedDraftSessionId, draftGeneration: draftGeneration)
    if Self.splitHasContentColumn, case let .page(workspaceId) = identity { return .workspace(workspaceId) }
    return identity
  }

  /// One `WorkspaceScreen` at one structural position; only its parameters
  /// vary by route. Combined with the detail identity above, a New Chat
  /// draft becomes its workspace in place.
  func detailScreen(for route: HomeRoute) -> some View {
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

  /// Keeps the route naming the pane the detail actually shows. The detail
  /// switches panes on a route *change*, so a route left on the pane a
  /// sidebar tap last asked for would swallow the next tap on that same row
  /// — the case where New Tab moves the workspace to a terminal and tapping
  /// the chat again does nothing until some other row is tapped first.
  ///
  /// Compact is exempt: it pushes a fresh screen per visit, so its route is
  /// never stale, and rewriting the top of that stack would remount it. So
  /// is a tab pushed on the iPhone Duo's page, for the same reason.
  func followWorkspacePaneSelection(_ selection: WorkspacePaneSelection) {
    guard layoutMode == .split, Self.splitHasContentColumn || navigation.path.count == 1,
      navigation.followPaneSelection(workspaceId: selection.workspaceId, paneId: selection.paneId)
    else { return }
    IOSNavigationDiagnostics.record(
      "home.followPaneSelection",
      "workspace=\(shortID(selection.workspaceId)) pane=\(shortID(selection.paneId))"
    )
  }

  /// Sets the split detail and drops any pushed sub-pages. Entering New
  /// Chat starts a new draft generation so a promoted workspace that
  /// shares the draft identity is remounted rather than reused.
  func selectDetail(_ route: HomeRoute?) {
    if route?.isNewChat ?? true {
      promotedDraftSessionId = nil
      draftGeneration = UUID()
    }
    detailPath = NavigationPath()
    navigation.select(route)
  }
}

/// Reads whether the sidebar is tiled or floats over the detail, from where
/// the detail starts.
private struct DetailInsetReader: ViewModifier {
  @Binding var inset: CGFloat

  func body(content: Content) -> some View {
    content.onGeometryChange(for: CGFloat.self) { proxy in
      proxy.frame(in: .global).minX
    } action: { minX in
      inset = minX
    }
  }
}

/// The `WorkspaceScreen` inputs for a detail route, resolved without side
/// effects (destination construction stays read-only).
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
    case .folder:
      // Never shown: a folder's page has no tab beside it.
      isDraft = false
    case let .agent(serverId, workspaceId):
      // A page on its own shows the workspace's last tab beside it.
      self.serverId = serverId
      self.workspaceId = workspaceId
      isDraft = false
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
    }
  }
}
