import CodevisorCore
import CodevisorUI
import SwiftUI

/// Home's regular-width container for the unfolded iPhone Duo display: the
/// sidebar in the leading column and the selected workspace — or a New Chat
/// draft when nothing is selected — in the detail column, mirroring macOS.
/// The system collapses this to a stack on compact width, but Home swaps to
/// `stackContainer` instead so the compact experience stays byte-identical.
extension HomeView {
  static let sidebarColumnMinWidth: CGFloat = 300
  static let sidebarColumnIdealWidth: CGFloat = 340
  /// At least half the inner display, so the balanced split can align its
  /// divider with the fold when the device is held like a book.
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
      // Tiled vs overlay sidebar, read from where the detail starts.
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.frame(in: .global).minX
      } action: { minX in
        detailLeadingInset = minX
      }
    }
    .navigationSplitViewStyle(.balanced)
    // The workspace recorded the tap as its selection; the pending value
    // has done its job.
    .onChange(of: splitSelectedRowID) { _, _ in
      pendingSidebarSelection = nil
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      restoreAutoCollapsedSidebarIfWidened(to: width)
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
    sidebarColumnVisibility = .doubleColumn
    IOSNavigationDiagnostics.record("home.sidebar.restored", "width=\(Int(width))")
  }

  /// The sidebar list's selection. Reading follows what the detail shows;
  /// writing opens the tab through the same path a phone row takes.
  var splitSelection: Binding<UUID?> {
    Binding(
      get: { pendingSidebarSelection ?? splitSelectedRowID },
      set: { id in
        guard let id,
          let section = sidebarSections.first(where: { $0.rows.contains { $0.id == id } }),
          let row = section.rows.first(where: { $0.id == id })
        else { return }
        pendingSidebarSelection = id
        sidebarActions.open(row, section)
        dismissOverlaySidebarAfterSelection()
      }
    )
  }

  @ViewBuilder
  var splitDetail: some View {
    if !hasRemoteMachines && !showsSampleSidebar {
      // The sidebar column carries the connect prompt; the detail stays a
      // quiet surface until a machine is paired.
      ChatSurfaceBackground()
        .ignoresSafeArea()
    } else {
      detailScreen(for: navigation.detailRoute(fallbackServerId: nil))
        // A draft keeps its identity through its first send so the
        // composer, transcript, and keyboard are not remounted.
        .id(navigation.detailIdentity(promotedDraftSessionId: promotedDraftSessionId, draftGeneration: draftGeneration))
    }
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
  /// never stale, and rewriting the top of that stack would remount it.
  func followWorkspacePaneSelection(_ selection: WorkspacePaneSelection) {
    guard layoutMode == .split,
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

  /// The pane row highlighted as the split selection. The presented
  /// workspace's persisted selection is what the detail actually shows, so
  /// it wins: a New Tab, a conversion, a close, or an agent navigating the
  /// workspace all move it without changing Home's route. The route only
  /// stands in before the workspace has recorded a selection.
  var splitSelectedRowID: UUID? {
    guard layoutMode == .split else { return nil }
    // Repository reads are not observable; these tokens re-read on writes.
    _ = workspaceRevision
    _ = environment.workspaceSync.revision
    if let presented = navigation.presentedWorkspace,
      let workspace = environment.workspaces.workspace(id: presented.workspaceId),
      let tab = workspace.selectedCenterTab,
      let paneId = tab.root.group(id: tab.activeLeafId)?.selectedPaneId
    {
      return paneId
    }
    return navigation.selectedPaneId { chatId in
      sidebarSections.lazy.flatMap(\.rows).first { $0.chatSessionId == chatId }?.id
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
    case let .workspace(
      serverId, workspaceId, anchorSessionId, preferredChatSessionId, preferredPaneId, preferredLeafId):
      sessionId = anchorSessionId
      self.serverId = serverId
      self.workspaceId = workspaceId
      self.preferredChatSessionId = preferredChatSessionId
      self.preferredPaneId = preferredPaneId
      self.preferredLeafId = preferredLeafId
      initialController = projectList.sessions.first(where: {
        $0.serverId == serverId && $0.id == anchorSessionId
      }).flatMap { session in
        ChatControllerCache.shared.existingController(sessionId: session.id, serverId: serverId)
      }
      isDraft = false
    }
  }
}
