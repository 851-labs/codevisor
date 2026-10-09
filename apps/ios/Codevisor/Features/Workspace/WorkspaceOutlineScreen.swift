import CodevisorCore
import CodevisorUI
import SwiftUI

/// A workspace's page, as Notes shows a folder: the workspaces nested under
/// it, which disclose and open the same way the root's do, then its tabs.
/// Tapping a tab opens it; New Tab at the bottom opens a new one from its
/// autocomplete.
struct WorkspaceOutlineScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.workspaceRowActions) private var actions

  let serverId: String
  let workspaceId: UUID
  /// Beside a sidebar (iPad's middle column), the open tab is a selection.
  var selectedTab: Binding<UUID?>? = nil

  @State private var expanded: Set<UUID> = []
  @State private var showsWorkspaces = true
  @State private var showsTabs = true
  @State private var showsNewTabMenu = false

  private var navigation: NavigationStore { environment.navigationStore }

  var body: some View {
    // The projection isn't observed directly; the revision is what changes.
    let _ = navigation.revision
    let row = navigation.agentSidebar.row(id: workspaceId)
    let workspace = environment.workspaces.workspace(id: workspaceId)
    let tabs = workspace.map { WorkspaceTabRowBuilder(environment: environment).tabRows(for: $0) } ?? []
    let children = row?.children ?? []
    Group {
      if let selectedTab {
        List(selection: selectedTab) { sections(row: row, children: children, tabs: tabs) }
      } else {
        List { sections(row: row, children: children, tabs: tabs) }
      }
    }
    .listStyle(.sidebar)
    .navigationTitle(row?.title ?? workspace?.name ?? "")
    .toolbar { toolbar(row: row) }
  }

  @ViewBuilder
  private func sections(row: AgentSidebarRow?, children: [AgentSidebarRow], tabs: [HomeSidebarTabRow]) -> some View {
    if !children.isEmpty {
      Section("Workspaces", isExpanded: $showsWorkspaces) {
        WorkspaceOutline(rows: children, owner: row, expanded: $expanded, isSelectable: selectedTab != nil)
      }
    }
    Section("Tabs", isExpanded: $showsTabs) {
      ForEach(tabs) { tab in tabRow(tab) }
        .onMove { source, destination in moveTab(in: tabs, from: source, to: destination) }
    }
  }

  @ViewBuilder
  private func tabRow(_ tab: HomeSidebarTabRow) -> some View {
    let label = HStack(spacing: 10) {
      HomeSidebarTabIcon(row: tab, serverId: serverId)
        .frame(width: 20)
      Text(tab.title).lineLimit(1)
    }
    let isHome = tab.chatSessionId != nil && tab.chatSessionId == homeChatId
    Group {
      if selectedTab != nil {
        label.tag(tab.id)
      } else {
        NavigationLink(value: route(for: tab)) { label }
      }
    }
    .swipeActions(edge: .trailing) {
      if !isHome {
        Button("Close", systemImage: "xmark", role: .destructive) { close(tab) }
      }
    }
    .contextMenu {
      if !isHome {
        Button("Close Tab", systemImage: "xmark", role: .destructive) { close(tab) }
      }
    }
  }

  @ToolbarContentBuilder
  private func toolbar(row: AgentSidebarRow?) -> some ToolbarContent {
    if let row {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          WorkspaceRowMenu(row: row, owner: owner(of: row))
        } label: {
          Label("More", systemImage: "ellipsis")
        }
      }
    }
    ToolbarSpacer(placement: .bottomBar)
    ToolbarItem(placement: .bottomBar) {
      Button("New Tab", systemImage: "plus") { showsNewTabMenu = true }
        .popover(isPresented: $showsNewTabMenu) {
          NewTabMenu(
            isPresented: $showsNewTabMenu,
            supportsSimulator: environment.machines.statusByMachineId[serverId]?.supportsSimulator == true,
            client: environment.machines.client(for: serverId),
            iconCacheNamespace: serverId,
            onChoose: { openNewTab($0) }
          )
        }
    }
  }

  private var homeChatId: UUID? {
    environment.workspaces.workspace(id: workspaceId).flatMap { navigation.homeChatId(of: $0) }
  }

  private func owner(of row: AgentSidebarRow) -> AgentSidebarRow? {
    environment.workspaces.workspace(id: row.id)?.parentWorkspaceId.flatMap { navigation.agentSidebar.row(id: $0) }
  }

  /// A chat opens by its session, so its chat always wins; other tabs open
  /// on their exact pane.
  func route(for tab: HomeSidebarTabRow) -> HomeRoute {
    .workspace(
      serverId: serverId, workspaceId: workspaceId, anchorSessionId: tab.chatSessionId,
      preferredChatSessionId: tab.chatSessionId, preferredPaneId: tab.chatSessionId == nil ? tab.id : nil)
  }

  /// The tab screen opens the new tab; this page has no panes of its own.
  private func openNewTab(_ choice: NewTabChoice) {
    WorkspaceNewTabRequests.shared.request(choice, in: workspaceId)
    actions.openTab(
      .workspace(serverId: serverId, workspaceId: workspaceId, anchorSessionId: nil, preferredChatSessionId: nil))
  }

  /// Moves a dragged tab on every device. Rows of a split belong to one
  /// tab, so moving any of them moves the tab, in front of the tab it was
  /// dropped above. Agents nested in the tab bar keep their places.
  private func moveTab(in tabs: [HomeSidebarTabRow], from source: IndexSet, to destination: Int) {
    guard let row = source.first, let tabId = tabs[row].tabId,
      let workspace = environment.workspaces.workspace(id: workspaceId)
    else { return }
    let successor = SharedTabOrder.successor(
      of: tabId, droppedAt: destination, rowTabIds: tabs.map { $0.tabId ?? $0.id })
    environment.workspaceSync.moveTab(tabId, before: successor, inWorkspace: workspaceId)
    guard let updated = environment.workspaces.workspace(id: workspace.id) else { return }
    var reordered = updated.centerTabs[...]
    let entries = navigation.tabStrip(for: updated).map { entry -> TabStripEntry in
      guard case .tab = entry, let next = reordered.popFirst() else { return entry }
      return .tab(next)
    }
    navigation.publishTabStripOrder(of: updated, entries: entries)
  }

  /// Closes a tab without opening it: a chat is closed like any chat; other
  /// panes leave the workspace's layout and the shared registry.
  private func close(_ tab: HomeSidebarTabRow) {
    withAnimation {
      if let chatId = tab.chatSessionId, let session = environment.projectList.session(chatId, serverId: serverId) {
        environment.closeSession(session)
      } else if let workspace = environment.workspaces.workspace(id: workspaceId) {
        closePane(tab.id, in: workspace)
      }
    }
    switch tab.icon {
    case .plugin: PluginPaneCache.shared.remove(paneId: tab.id)
    case .browser: BrowserPaneCache.shared.remove(paneId: tab.id)
    case .review: ReviewPaneCache.shared.remove(paneId: tab.id)
    case .simulator: SimulatorPaneCache.shared.remove(paneId: tab.id)
    default: break
    }
  }

  private func closePane(_ paneId: UUID, in workspace: Workspace) {
    var state = WorkspaceScreen.compactPaneState(from: workspace)
    if let closed = state.panes.first(where: { $0.id == paneId }), closed.kind == .terminal {
      TerminalSessionCache.shared.remove(terminalKey: closed.terminalKey)
    }
    let replacement: PaneDescriptorState?
    if state.panes.count == 1 {
      replacement = state.replacePaneWithNewTab(id: paneId)
      guard replacement != nil else { return }
    } else {
      replacement = nil
      guard state.closePane(id: paneId) != nil else { return }
    }
    var updated = workspace
    WorkspaceScreen.applyCompactPaneState(state, to: &updated)
    environment.workspaces.save(updated)
    environment.workspaceSync.deletePane(
      id: paneId, workspaceId: workspace.id, optimisticReplacement: replacement,
      client: environment.machines.client(for: workspace.serverId))
  }
}
