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

  /// Opens an agent on its own chat (or the given one): the agent itself,
  /// never whichever tab happened to be in front last time.
  func openAgent(_ workspaceId: UUID, chat chatId: UUID?) {
    guard let workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    let chat = chatId ?? environment.navigationStore.homeChatId(of: workspace)
    if let chat, let session = projectList.session(chat, serverId: workspace.serverId) {
      openChat(session)
      return
    }
    openRoute(
      .workspace(
        serverId: workspace.serverId, workspaceId: workspace.id, anchorSessionId: nil,
        preferredChatSessionId: nil))
  }

  /// The split selection: the subagent chat in front, else the shown
  /// workspace. Choosing a row opens it like a phone tap.
  private var agentSelection: Binding<UUID?> {
    Binding(
      get: {
        guard let presented = navigation.presentedWorkspace else { return nil }
        if let workspace = environment.workspaces.workspace(id: presented.workspaceId),
          let tab = workspace.selectedCenterTab,
          let chat = tab.root.group(id: tab.activeLeafId)?.selectedPane?.chatSessionId,
          chat != environment.navigationStore.homeChatId(of: workspace)
        {
          return chat
        }
        return presented.workspaceId
      },
      set: { id in
        guard let id else { return }
        if environment.workspaces.workspace(id: id) != nil {
          openAgent(id, chat: nil)
        } else if let workspaceId = environment.workspaces.workspaceId(forSession: id) {
          openAgent(workspaceId, chat: id)
        }
        dismissOverlaySidebarAfterSelection()
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
