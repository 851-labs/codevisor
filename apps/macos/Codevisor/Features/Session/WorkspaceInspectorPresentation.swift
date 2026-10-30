import CodevisorClient
import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceInspectorOpenRequest: Equatable {
  let id = UUID()
  let workspaceId: UUID
  let destination: WorkspaceInspectorView.Destination
}

struct WorkspaceInspectorPresentation: ViewModifier {
  private struct Inspected {
    let workspace: Workspace
    let project: Project
    let chat: ChatSession?
  }

  private struct RefreshKey: Equatable {
    let workspaceId: UUID
    let tab: WorkspaceInspectorTab
    let activity: Date?
    let usageChatId: UUID?
    let usageAccount: WorkspaceInspectorUsageModel.Account?
  }

  static let usageRefreshInterval: Duration = .seconds(120)

  static let presentedKey = "workspace.inspectorPresented"

  @Environment(AppEnvironment.self) private var environment
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(Self.presentedKey, default: false) private var isPresented
  @ClientPreference("workspace.inspectorTab", default: WorkspaceInspectorTab.info) private var tab
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(FeatureFlag.developerMode.preferenceKey, default: false) private var developerMode
  @ClientPreference(SidebarGrouping.preferenceKey, default: SidebarGrouping.flat) private var sidebarGrouping
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) private var pinnedWorkspaceIDs: [String]
  @State private var media = WorkspaceInspectorMediaModel()
  @State private var fileTree = WorkspaceInspectorFileTreeModel()
  @State private var imageStores = WorkspaceInspectorImageStores()
  @State private var usage = WorkspaceInspectorUsageModel()
  let store: SessionStore?
  @Binding var selection: SidebarSelection?
  var revealRequest: SidebarRevealRequest?
  var idealInspectorWidth: CGFloat = 260

  func body(content: Content) -> some View {
    let inspected = inspectedWorkspace
    let showsDrawer = inspected != nil && !panelLayout.docksInspector && panelLayout.activeDrawer == .trailing
    let isVisible = panelLayout.docksInspector ? isPresented : showsDrawer
    let visibleTab = inspected.map { shownTab(for: $0) } ?? tab
    content
      .inspector(
        isPresented: Binding(
          get: { inspected != nil && isPresented && panelLayout.docksInspector },
          set: { if panelLayout.docksInspector { isPresented = $0 } }
        )
      ) {
        if let store, let inspected {
          inspectorView(store, inspected, isVisible: panelLayout.docksInspector && isVisible)
            .inspectorColumnWidth(min: 220, ideal: idealInspectorWidth, max: 400)
            .toolbar {
              ToolbarSpacer(.flexible)
              ToolbarItem {
                Button(action: toggleInspector) {
                  Label(isVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .help(isVisible ? "Hide Inspector" : "Show Inspector")
              }
            }
        }
      }
      .overlay {
        AdaptiveDrawerLayer(isPresented: showsDrawer, edge: .trailing, width: min(300, panelLayout.windowWidth - 16)) {
          if let store, let inspected {
            inspectorView(store, inspected, isVisible: showsDrawer)
          }
        }
      }
      .task(id: inspected.flatMap { isVisible ? refreshKey(for: $0) : nil }) {
        guard let inspected, isVisible else { return }
        await reload(inspected)
        guard visibleTab == .harness, harnessChat(for: inspected) != nil else { return }
        while true {
          do { try await Task.sleep(for: Self.usageRefreshInterval) } catch { return }
          await reloadUsage(inspected)
        }
      }
      .task(id: isVisible && visibleTab == .harness ? usageAccounts : nil) {
        guard isVisible, visibleTab == .harness else { return }
        await usage.prefetch(usageCandidates) { environment.machines.client(for: $0) }
      }
      .focusedSceneValue(\.workspaceInspector, inspected.map { actions(for: $0, isVisible: isVisible) })
  }

  private func actions(for inspected: Inspected, isVisible: Bool) -> WorkspaceInspectorActions {
    WorkspaceInspectorActions(
      isVisible: isVisible, tabs: tabs(for: inspected), harnessId: harnessChat(for: inspected)?.harnessId,
      toggle: toggleInspector, show: showInspector)
  }

  private func toggleInspector() {
    if panelLayout.docksInspector {
      isPresented.toggle()
    } else {
      panelLayout.toggleDrawer(.trailing)
    }
  }

  private func showInspector(_ destination: WorkspaceInspectorTab) {
    tab = destination
    if panelLayout.docksInspector {
      isPresented = true
    } else if panelLayout.activeDrawer != .trailing {
      panelLayout.toggleDrawer(.trailing)
    }
  }

  private func inspectorView(_ store: SessionStore, _ inspected: Inspected, isVisible: Bool) -> some View {
    let workspace = inspected.workspace
    let chat = harnessChat(for: inspected)
    let bot = botsEnabled ? environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) : nil
    let desktop = MachineDesktopRegistry.shared.session(
      for: workspace, project: inspected.project, environment: environment)
    return WorkspaceInspectorView(
      workspace: workspace,
      project: inspected.project,
      branch: store.gitLookups.branch(for: workspace),
      pullRequest: store.gitLookups.pullRequest(for: workspace),
      machineName: environment.machines.fleetMachineName(for: workspace.serverId),
      machineSymbol: environment.machines.machine(for: workspace.serverId)?.icon.systemImage,
      showsDebugSection: developerMode,
      showsBotTranscript: bot?.isConversational == true,
      harnessChat: chat,
      tasks: shownTab(for: inspected) == .info ? mainChatTasks(of: workspace, store: store) : [],
      parent: shownTab(for: inspected) == .info ? parent(of: workspace, store: store) : nil,
      agents: shownTab(for: inspected) == .info ? agents(of: workspace, bot: bot, store: store) : [],
      store: store,
      usage: usage,
      tabs: tabs(for: inspected),
      tab: Binding(get: { shownTab(for: inspected) }, set: { tab = $0 }),
      media: media,
      fileTree: fileTree,
      activeFilePath: activeDocumentPath(in: workspace),
      chatUsage: chat.flatMap {
        store.controllers[SessionStore.SessionKey(serverId: $0.serverId, sessionId: $0.id)]?.model?.usage
      },
      activity: activity(in: workspace),
      client: environment.machines.client(for: workspace.serverId),
      desktop: desktop,
      onOpenDesktop: {
        guard let desktop else { return }
        Task {
          guard await desktop.register() else { return }
          MachineDesktopWindows.shared.present(desktop, machineId: workspace.serverId, environment: environment)
        }
      },
      onReload: { Task { await reload(inspected) } },
      onOpen: { destination in
        store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(
          workspaceId: workspace.id, destination: destination)
      }
    )
    .environment(\.attachmentImages, imageStores.store(for: workspace.serverId, environment: environment))
    .environment(\.isWorkspaceInspectorVisible, isVisible)
  }

  private func mainChatTasks(of workspace: Workspace, store: SessionStore) -> [WorkspaceInspectorTask] {
    guard let chat = mainChat(of: workspace) else { return [] }

    return WorkspaceInspectorMainChatTasks(
      workspace: workspace, chat: chat, store: store, client: environment.machines.client(for: chat.serverId)
    ).tasks
  }

  private func parent(of workspace: Workspace, store: SessionStore) -> WorkspaceInspectorAgent? {
    inspectorAgents(parentItems(of: workspace), store: store).first
  }

  private func agents(of workspace: Workspace, bot: Bot?, store: SessionStore) -> [WorkspaceInspectorAgent] {
    inspectorAgents(agentItems(of: workspace, bot: bot), store: store)
  }

  private func inspectorAgents(_ items: [WorkspaceSidebarItem], store: SessionStore) -> [WorkspaceInspectorAgent] {
    let content = SidebarRowContent(
      environment: environment, store: store, grouping: sidebarGrouping,
      rowDetails: ClientPreferences.shared.sidebarRowDetails)
    let listing = SidebarWorkspaceListing(
      environment: environment, botsEnabled: botsEnabled, grouping: sidebarGrouping, pinnedIDs: pinnedWorkspaceIDs,
      machineOrder: [], projectOrder: [])
    let navigator = SidebarWorkspaceNavigator(environment: environment, store: store, selection: $selection)
    return items.compactMap { content.listItem(for: $0) }
      .map { item in
        let workspace = item.workspace
        return WorkspaceInspectorAgent(
          id: workspace.id, name: workspace.name,
          subtitle: content.subtitle(for: workspace, isPinned: false), icon: content.icon(for: item),
          pullRequest: content.pullRequest(for: workspace),
          machine: content.machine(for: workspace, headingNamesMachine: listing.headingNamesMachine(workspace.id))
        ) {
          revealRequest?.rowID = workspace.id
          navigator.activate(item)
        }
      }
  }

  private func parentItems(of workspace: Workspace) -> [WorkspaceSidebarItem] {
    let sidebar = environment.navigationStore.workspaceEntries.sidebar
    guard let parentId = sidebar.first(where: { $0.id == workspace.id })?.parentWorkspaceId else { return [] }
    return sidebar.filter { $0.id == parentId }
  }

  private func agentItems(of workspace: Workspace, bot: Bot?) -> [WorkspaceSidebarItem] {
    let children = environment.navigationStore.workspaceEntries.sidebar.filter { $0.parentWorkspaceId == workspace.id }
    guard let bot else { return children }

    let botChildren = environment.botSidebarEntries.first { $0.bot.id == bot.id }?.children ?? []
    let listed = Set(botChildren.map(\.id))
    return botChildren + children.filter { !listed.contains($0.id) }
  }

  private func refreshKey(for inspected: Inspected) -> RefreshKey {
    let tab = shownTab(for: inspected)
    let usageChat = tab == .harness ? harnessChat(for: inspected) : nil
    return RefreshKey(
      workspaceId: inspected.workspace.id, tab: tab, activity: activity(in: inspected.workspace),
      usageChatId: usageChat?.id, usageAccount: usageChat.map(WorkspaceInspectorUsageModel.Account.init))
  }

  private func reload(_ inspected: Inspected) async {
    let workspace = inspected.workspace
    let client = environment.machines.client(for: workspace.serverId)
    let tab = shownTab(for: inspected)
    switch tab {
    case .files:
      await fileTree.show(root: workspace.rootDirectory, client: client)
    case .info, .media, .links:
      await media.reload(tab, workspaceId: workspace.id, client: client)
    case .harness:
      await reloadUsage(inspected)
    case .machine:
      break
    }
  }

  private func showsHarness(_ inspected: Inspected) -> Bool {
    guard inspected.workspace.selectedCenterTab != nil else { return inspected.chat != nil }
    let pane = inspected.workspace.focusedPane
    return pane?.kind == .chat && pane?.chatSessionId != nil
  }

  private func tabs(for inspected: Inspected) -> [WorkspaceInspectorTab] {
    WorkspaceInspectorTab.available(showsHarness: showsHarness(inspected))
  }

  private func shownTab(for inspected: Inspected) -> WorkspaceInspectorTab {
    tab == .harness && !showsHarness(inspected) ? .info : tab
  }

  private func harnessChat(for inspected: Inspected) -> ChatSession? {
    let workspace = inspected.workspace
    return workspace.focusedChatSessionId.flatMap {
      environment.projectList.session($0, serverId: workspace.serverId)
    } ?? inspected.chat
  }

  private func reloadUsage(_ inspected: Inspected) async {
    guard let chat = harnessChat(for: inspected) else { return }
    await usage.reload(chat, client: environment.machines.client(for: chat.serverId))
  }

  private var usageCandidates: [ChatSession] {
    environment.projectList.sessions
  }

  private var usageAccounts: Set<WorkspaceInspectorUsageModel.Account> {
    Set(usageCandidates.map(WorkspaceInspectorUsageModel.Account.init))
  }

  private func mainChat(of workspace: Workspace) -> ChatSession? {
    environment.workspaces.mainFirstChatSessionIds(in: workspace).lazy.compactMap {
      environment.projectList.session($0, serverId: workspace.serverId)
    }.first
  }

  private func activeDocumentPath(in workspace: Workspace) -> String? {
    guard let pane = workspace.focusedPane, pane.kind == .document else { return nil }
    return pane.documentPath
  }

  private func activity(in workspace: Workspace) -> Date? {
    environment.projectList.sessions
      .filter {
        $0.serverId == workspace.serverId && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
      }
      .map(\.sidebarStateChangedAt)
      .max()
  }

  private var inspectedWorkspace: Inspected? {
    guard let store else { return nil }
    switch selection {
    case let .bot(serverId, botId):
      guard let bot = environment.bots.bot(serverId: serverId, id: botId),
        let session = environment.projectList.session(bot.sessionId, serverId: serverId),
        let project = project(serverId: serverId, id: session.projectId)
      else { return nil }
      let workspace = environment.navigationStore.workspaceEntries.entry(bot.workspaceId).workspace
      return Inspected(
        workspace: workspace ?? store.workspace(for: session, project: project), project: project, chat: session)
    case let .session(serverId, sessionId):
      guard let session = environment.projectList.session(sessionId, serverId: serverId),
        let project = project(serverId: serverId, id: session.projectId)
      else { return nil }
      let entry = environment.workspaces.workspaceId(forSession: sessionId).map {
        environment.navigationStore.workspaceEntries.entry($0)
      }
      return Inspected(
        workspace: entry?.workspace ?? store.workspace(for: session, project: project), project: project,
        chat: session)
    case let .workspace(serverId, workspaceId):
      guard let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace,
        workspace.serverId == serverId,
        let project = project(serverId: serverId, id: workspace.projectId)
      else { return nil }
      return Inspected(workspace: workspace, project: project, chat: mainChat(of: workspace))
    case .archivedWorkspace, .newChat, .none:
      return nil
    }
  }

  private func project(serverId: String, id: UUID) -> Project? {
    environment.projectList.projects.first { $0.serverId == serverId && $0.id == id }
  }
}

@MainActor
final class WorkspaceInspectorImageStores {
  private var stores: [String: AttachmentImageStore] = [:]

  func store(for serverId: String, environment: AppEnvironment) -> AttachmentImageStore {
    if let existing = stores[serverId] { return existing }
    let client = { environment.machines.client(for: serverId) }
    let store = AttachmentImageStore(
      namespace: "\(serverId):workspace-media",
      fetch: { source in
        guard case let .attachment(fileId) = source else { throw CodevisorServerClientError.invalidResponse }
        return try await client().fileData(id: fileId)
      },
      fetchPreview: { source in
        guard case let .attachment(fileId) = source else { throw CodevisorServerClientError.invalidResponse }
        return try await client().filePreview(id: fileId)
      },
      version: { source in
        guard case let .attachment(fileId) = source else { return nil }
        return "attachment:\(fileId)"
      }
    )
    stores[serverId] = store
    return store
  }
}
