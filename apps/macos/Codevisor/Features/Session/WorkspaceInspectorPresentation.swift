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

  private struct InspectedPlace {
    let serverId: String
    let rootDirectory: String?
    let branch: String?
    let worktreeName: String?
    let pullRequest: ServerGitPullRequest?
  }

  private struct RefreshKey: Equatable {
    let shown: ShownView
    let activity: Date?
  }

  private struct ShownView: Equatable {
    let workspaceId: UUID
    let tab: WorkspaceInspectorTab
    let usageChatId: UUID?
    let usageAccount: WorkspaceInspectorUsageModel.Account?
  }

  static let usageRefreshInterval: Duration = .seconds(120)

  static let presentedKey = "workspace.inspectorPresented"

  @Environment(AppEnvironment.self) private var environment
  @Environment(AdaptivePanelLayout.self) private var panelLayout
  @ClientPreference(Self.presentedKey, default: false) private var isPresented
  @ClientPreference("workspace.inspectorTab", default: WorkspaceInspectorTab.info) private var tab
  @ClientPreference(FeatureFlag.developerMode.preferenceKey, default: false) private var developerMode
  @Environment(\.workspaceChildAgents) private var childAgents
  @State private var media = WorkspaceInspectorMediaModel()
  @State private var fileTree = WorkspaceInspectorFileTreeModel()
  @State private var imageStores = WorkspaceInspectorImageStores()
  @State private var usage = WorkspaceInspectorUsageModel()
  @State private var lastRefresh: RefreshKey?
  let store: SessionStore?
  @Binding var selection: SidebarSelection?
  var idealInspectorWidth: CGFloat = 260

  func body(content: Content) -> some View {
    let inspected = inspectedWorkspace
    let showsDrawer = inspected != nil && !panelLayout.docksInspector && panelLayout.activeDrawer == .trailing
    let isVisible = panelLayout.docksInspector ? isPresented : showsDrawer
    let visibleTab = inspected.map { shownTab(for: $0) } ?? tab
    let refresh = inspected.flatMap { isVisible ? refreshKey(for: $0) : nil }
    content
      .inspector(
        isPresented: Binding(
          get: { inspected != nil && isPresented && panelLayout.docksInspector },
          set: { if panelLayout.docksInspector { isPresented = $0 } }
        )
      ) {
        if let store, let inspected {
          inspectorView(store, inspected)
            .inspectorColumnWidth(min: 220, ideal: idealInspectorWidth, max: 400)
            .toolbar {
              ToolbarSpacer(.flexible)
              ToolbarItem {
                Button(action: toggleInspector) {
                  Label(PanelToggleShortcut.inspector.title(isVisible: isVisible), systemImage: "sidebar.trailing")
                }
                .help(PanelToggleShortcut.inspector.help(isVisible: isVisible))
              }
            }
        }
      }
      .overlay { inspectorDrawer(inspected, isPresented: showsDrawer) }
      .task(id: refresh) {
        let isSameView = lastRefresh?.shown == refresh?.shown
        lastRefresh = refresh
        guard let inspected, isVisible else { return }
        await reload(inspected, animatesUsage: isSameView)
        guard visibleTab == .harness, harnessChat(for: inspected) != nil else { return }
        while true {
          do { try await Task.sleep(for: Self.usageRefreshInterval) } catch { return }
          await reloadUsage(inspected, animated: true)
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

  private func inspectorDrawer(_ inspected: Inspected?, isPresented: Bool) -> some View {
    AdaptiveDrawerLayer(isPresented: isPresented, edge: .trailing, width: AdaptivePanelLayout.inspectorDrawerWidth) {
      if let store, let inspected {
        inspectorView(store, inspected)
      }
    }
  }

  private func inspectorView(_ store: SessionStore, _ inspected: Inspected) -> some View {
    let workspace = inspected.workspace
    let chat = harnessChat(for: inspected)
    let place = place(of: inspected, chat: chat, store: store)
    let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId)
    let desktop = MachineDesktopRegistry.shared.session(
      for: workspace, project: inspected.project, environment: environment)
    return WorkspaceInspectorView(
      workspace: workspace,
      project: chat.flatMap(project(of:)) ?? inspected.project,
      branch: place.branch,
      worktreeName: place.worktreeName,
      pullRequest: place.pullRequest,
      machineName: environment.machines.fleetMachineName(for: place.serverId),
      machineSymbol: environment.machines.machine(for: place.serverId)?.icon.systemImage,
      showsDebugSection: developerMode,
      showsBotTranscript: bot != nil,
      harnessChat: chat,
      tasks: shownTab(for: inspected) == .info ? mainChatTasks(of: workspace, store: store) : [],
      parent: shownTab(for: inspected) == .info ? chat.flatMap { childAgents?.parent(of: $0) } : nil,
      agents: shownTab(for: inspected) == .info ? chat.flatMap { childAgents?.children(of: $0) } ?? [] : [],
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
      subscriptionsRevision: environment.machines.pluginSubscriptionsRevision,
      client: environment.machines.client(for: workspace.serverId),
      desktop: desktop,
      onOpenDesktop: {
        guard let desktop else { return }
        Task {
          guard (try? await desktop.register()) != nil else { return }
          MachineDesktopWindows.shared.present(desktop, machineId: workspace.serverId, environment: environment)
        }
      },
      onReload: { Task { await reload(inspected, animatesUsage: true) } },
      onOpen: { destination in
        store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(
          workspaceId: workspace.id, destination: destination)
      }
    )
    .environment(\.attachmentImages, imageStores.store(for: workspace.serverId, environment: environment))
  }

  private func mainChatTasks(of workspace: Workspace, store: SessionStore) -> [WorkspaceInspectorTask] {
    guard let chat = mainChat(of: workspace) else { return [] }

    return WorkspaceInspectorMainChatTasks(
      workspace: workspace, chat: chat, store: store, client: environment.machines.client(for: chat.serverId)
    ).tasks
  }

  private func refreshKey(for inspected: Inspected) -> RefreshKey {
    let tab = shownTab(for: inspected)
    let usageChat = tab == .harness ? harnessChat(for: inspected) : nil
    let shown = ShownView(
      workspaceId: inspected.workspace.id, tab: tab, usageChatId: usageChat?.id,
      usageAccount: usageChat.map(WorkspaceInspectorUsageModel.Account.init))
    return RefreshKey(shown: shown, activity: activity(in: inspected.workspace))
  }

  private func reload(_ inspected: Inspected, animatesUsage: Bool) async {
    let workspace = inspected.workspace
    let client = environment.machines.client(for: workspace.serverId)
    let tab = shownTab(for: inspected)
    switch tab {
    case .files:
      let place = place(of: inspected, chat: harnessChat(for: inspected), store: store)
      await fileTree.show(
        root: place.rootDirectory, client: environment.machines.client(for: place.serverId),
        isLocal: environment.machines.machine(for: place.serverId)?.isLocal == true)
    case .info, .media, .links:
      await media.reload(tab, workspaceId: workspace.id, client: client)
    case .harness:
      await reloadUsage(inspected, animated: animatesUsage)
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

  private func place(of inspected: Inspected, chat: ChatSession?, store: SessionStore?) -> InspectedPlace {
    let workspace = inspected.workspace
    let fallback = InspectedPlace(
      serverId: workspace.serverId, rootDirectory: workspace.rootDirectory,
      branch: store?.gitLookups.branch(for: workspace), worktreeName: workspace.worktreeName,
      pullRequest: store?.gitLookups.pullRequest(for: workspace))
    guard let chat, let checkout = environment.navigationStore.projection.checkout(for: chat) else { return fallback }
    guard let git = checkout.git else {
      return InspectedPlace(
        serverId: checkout.serverId, rootDirectory: checkout.path,
        branch: fallback.branch, worktreeName: checkout.worktreeName, pullRequest: fallback.pullRequest)
    }
    return InspectedPlace(
      serverId: checkout.serverId, rootDirectory: checkout.path,
      branch: SidebarGitLookups.head(of: git), worktreeName: checkout.worktreeName, pullRequest: git.pullRequest)
  }

  private func project(of chat: ChatSession) -> Project? {
    environment.projectList.projects.first { $0.serverId == chat.serverId && $0.id == chat.projectId }
  }

  private func harnessChat(for inspected: Inspected) -> ChatSession? {
    let workspace = inspected.workspace
    if let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId),
      let agent = environment.openAgentChat(of: bot)
    {
      return agent
    }
    return workspace.focusedChatSessionId.flatMap {
      environment.projectList.chat($0, preferring: workspace.serverId)
    } ?? inspected.chat
  }

  private func reloadUsage(_ inspected: Inspected, animated: Bool) async {
    guard let chat = harnessChat(for: inspected) else { return }
    await usage.reload(chat, client: environment.machines.client(for: chat.serverId), animated: animated)
  }

  private var usageCandidates: [ChatSession] {
    environment.projectList.sessions
  }

  private var usageAccounts: Set<WorkspaceInspectorUsageModel.Account> {
    Set(usageCandidates.map(WorkspaceInspectorUsageModel.Account.init))
  }

  private func mainChat(of workspace: Workspace) -> ChatSession? {
    environment.workspaces.mainFirstChatSessionIds(in: workspace).lazy.compactMap {
      environment.projectList.chat($0, preferring: workspace.serverId)
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
