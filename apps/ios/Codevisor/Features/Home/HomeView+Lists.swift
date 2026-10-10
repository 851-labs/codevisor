import CodevisorCore
import CodevisorUI
import SwiftUI

// MARK: - Lists

extension HomeView {
  /// Keep pull to refresh available in every connected-machine state. A
  /// refresh action only installs a refresh control when it reaches a
  /// supported scroll container, so loading, empty, and unavailable states
  /// each need a real scroll surface rather than a static replacement view.
  @ViewBuilder
  var refreshableNavigationContent: some View {
    switch launch {
    case .content:
      sidebarList
    case .empty, .onboarding:
      refreshableState(allowsStateHitTesting: false) {
        emptyState
      }
    case .loading:
      // Nothing is cached for any machine yet: the one legitimate spinner.
      // Every later launch shows the cached list instead.
      refreshableState(allowsStateHitTesting: false) {
        HomeNavigationSyncView(state: .loading(machineName: "your machines"))
      }
    }
  }

  /// The live sidebar builds its own sections, so Home's body depends on
  /// none of the workspaces it lists. The handler keeps one identity; only
  /// its closures are refreshed here.
  private var sidebarList: some View {
    HomeAgentList(
      actions: agentListActions,
      selection: layoutMode == .split ? agentSelection : nil
    )
  }

  private var agentListActions: HomeAgentListActions {
    HomeAgentListActions(
      open: { workspaceId, chatId in openAgent(workspaceId, chat: chatId) },
      rename: { workspaceId in
        guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
        workspaceRenameTitle = workspace.name
        renamingWorkspace = workspace
      },
      archive: { workspaceId in
        guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
        withSidebarReflow { environment.archiveWorkspace(workspace) }
      },
      didSelectInSplit: { dismissOverlaySidebarAfterSelection() },
      refresh: { await refreshNavigation() }
    )
  }

  /// What workspace and tab rows ask of Home, wherever they are listed.
  var workspaceRowActions: WorkspaceRowActions {
    let list = agentListActions
    return WorkspaceRowActions(
      openPage: { serverId, workspaceId in openRoute(.agent(serverId: serverId, workspaceId: workspaceId)) },
      openFolder: { folderId in openRoute(.folder(folderId)) },
      openTab: { route in navigation.openTab(route, mode: layoutMode) },
      rename: list.rename,
      archive: list.archive
    )
  }

  /// Opens a workspace: its page on a phone, as Notes opens a folder. Beside
  /// a sidebar, and when a chat is named, it opens on that chat (the
  /// workspace's own when none is) through its page.
  func openAgent(_ workspaceId: UUID, chat chatId: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    if chatId == nil, layoutMode == .stack {
      openRoute(.agent(serverId: workspace.serverId, workspaceId: workspace.id))
      return
    }
    let chat = chatId ?? environment.navigationStore.homeChatId(of: workspace)
    if let chat, let session = projectList.session(chat, serverId: workspace.serverId) {
      openChat(session)
      return
    }
    navigation.openTab(
      .workspace(
        serverId: workspace.serverId, workspaceId: workspace.id, anchorSessionId: nil,
        preferredChatSessionId: nil),
      mode: layoutMode)
  }

  /// The split selection: the workspace whose page or tab is shown.
  /// Choosing one shows its page, as Notes selects a folder.
  private var agentSelection: Binding<UUID?> {
    Binding(
      get: { navigation.selectedWorkspace?.workspaceId },
      set: { id in
        guard let id, let workspace = environment.workspaces.workspace(id: id) else { return }
        openRoute(.agent(serverId: workspace.serverId, workspaceId: workspace.id))
        if !Self.splitHasContentColumn { dismissOverlaySidebarAfterSelection() }
      })
  }

  #if DEBUG
    /// Fixture navigation with local reordering and no fleet mutations.
    var sampleSidebar: some View {
      HomeSidebarSampleData.Sidebar()
    }
  #endif

  /// Mail-style empty state: the navigation title already supplies the
  /// context, so the body needs only a quiet confirmation that it is empty.
  var emptyState: some View {
    Text("No Workspaces")
      .font(.title3.weight(.bold))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
