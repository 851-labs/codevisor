import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI

struct CodevisorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var runtime = AppRuntime.shared

  var body: some Scene {
    MainWindowScene(runtime: runtime)
    ClientSettingsScene(runtime: runtime)
  }
}

struct RootView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.openSettings) var openClientSettings
  @State var clientWindow = ClientWindowControl()
  @State var navigation = WindowNavigation()
  @State private var sidebarRevealRequest = SidebarRevealRequest()
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) var sidebarMode
  @State var botEditor: BotEditorTarget?
  @State var store: SessionStore?
  @State private var requiresInitialNewChatProjectResolution = false
  @State var panelLayout = AdaptivePanelLayout()
  @State private var commandPalette = CommandPalette()
  @State private var handlerIdentity = HandlerIdentity.unique

  var selection: SidebarSelection? {
    get { navigation.selection }
    nonmutating set { navigation.selection = newValue }
  }

  private var selectionRef: SidebarSelectionRef {
    SidebarSelectionRef(navigation)
  }

  var body: some View {
    mainSplit
      .environment(panelLayout)
      .modifier(
        ClientControlModifier(
          name: Host.current().localizedName ?? "Codevisor Mac", platform: "macos",
          context: clientControlContext, navigate: navigateClient, control: controlClient
        )
      )
      .background(ClientWindowReader(control: clientWindow).frame(width: 0, height: 0))
      .background(
        WindowFocusReader(
          onKeyChange: { [store] in store?.setWindowFocused($0) },
          onClose: { [store] in store?.windowClosed() }
        )
        .frame(width: 0, height: 0)
      )
      .background(
        SidebarSelectionReader(selection: selectionRef) { selection in
          RootTitlebar(selection: selection, panelLayout: panelLayout)
        }
      )
      .environment(\.openChat, OpenChatAction(identity: handlerIdentity) { await openChat($0) })
      .environment(\.isAppUpdateInProgress, environment.isUpdateInProgress)
      .task(id: store.map(ObjectIdentifier.init)) { readBotMascotActivity() }
      .overlay { ErrorBannerLayer() }
      .overlay { CommandPaletteOverlay(palette: commandPalette, store: store) }
      .focusedSceneValue(\.commandPalette, commandPalette)
      .focusedSceneValue(\.rootSidebarActions, rootActions)
      .sheet(item: $botEditor) { target in
        BotEditorSheet(target: target, environment: environment, store: store) { bot in
          selection = .bot(serverId: bot.serverId, id: bot.id)
        }
      }
      .background(
        WindowLayoutReader { panelLayout.updateWindow(width: $0, isFullScreen: $1) }.frame(width: 0, height: 0)
      )
      .task(id: environment.machines.sandboxMachineProfilesLoadKey) {
        await environment.machines.loadSandboxMachineProfiles()
      }
      .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenChatNotification)) { note in
        guard let sessionIdString = note.userInfo?["sessionId"] as? String,
          let sessionId = UUID(uuidString: sessionIdString),
          let serverId = note.userInfo?["serverId"] as? String
        else { return }
        openNotificationSession(sessionId, serverId: serverId)
      }
      .task {
        if store == nil {
          let created = SessionStore(environment: environment)
          store = created
          navigation.attach(store: created, environment: environment)
          created.setWindowFocused(clientWindow.window?.isKeyWindow == true)
          ChromiumAutomationBridge.shared.addStore(created)
        }
        if !AppPreview.isRunning {
          await environment.cloud.bootstrap()
        }
      }
      .modifier(SidebarModeSelectionMemory(selection: selectionRef) { panelLayout.dismissDrawer() })
      .modifier(TabSwitchBenchSteps(store: store, window: clientWindow))
      .modifier(SidebarSelectionHistory(selection: selectionRef, revealRequest: sidebarRevealRequest))
      .modifier(UpdateCenterUpkeep())
      .modifier(ConnectionRecoveryUpkeep())
      .modifier(ChromiumBrowserHostSync())
      .modifier(CloudAuthDeeplinkHandling())
      .modifier(KeyboardNavigationPrompt())
  }

  private func openNotificationSession(_ sessionId: UUID, serverId: String) {
    guard let session = environment.projectList.session(sessionId, serverId: serverId) else { return }
    selection = store?.selectChat(session) ?? .session(serverId: serverId, id: sessionId)
  }

  private func applySelectedSessionDisposition(_ disposition: WorkspaceRouteDisposition) {
    guard case let .session(serverId, sessionId) = selection else { return }
    switch disposition {
    case .keep:
      break
    case let .selectSession(replacementId):
      guard replacementId != sessionId else { return }
      if let replacement = environment.projectList.session(replacementId, serverId: serverId) {
        store?.selectChat(replacement)
      }
      selection = .session(serverId: serverId, id: replacementId)
    case .dismiss:
      selection = archivedWorkspace(of: sessionId, serverId: serverId) ?? .newChat(nil)
    }
  }

  private func archivedWorkspace(of sessionId: UUID, serverId: String) -> SidebarSelection? {
    guard let workspaceId = environment.workspaces.workspaceId(forSession: sessionId),
      environment.navigationStore.workspaceEntries.entry(workspaceId).workspace?.isArchived == true
    else { return nil }
    return .archivedWorkspace(serverId: serverId, id: workspaceId)
  }

  private var detailSubtitle: String {
    let entries = environment.navigationStore.workspaceEntries
    switch selection {
    case let .archivedWorkspace(serverId, id):
      let workspace = entries.entry(id).workspace
      return workspace?.serverId == serverId && workspace?.isArchived == true ? "Archived" : ""
    case let .workspace(serverId, id):
      let workspace = entries.entry(id).workspace
      return workspace?.serverId == serverId && workspace?.isRestoring == true ? "Restoring" : ""
    case .session, .bot, .newChat, .none:
      return ""
    }
  }

  private var mainSplit: some View {
    RootSplitView(store: store, windowControl: clientWindow) {
      RootSidebar(selection: selectionRef, botEditor: $botEditor, store: store, revealRequest: sidebarRevealRequest)
    } detail: {
      Group {
        if let store {
          detail(store)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .navigationSubtitle(detailSubtitle)
      .toolbar {
        BotComposeToolbarItem(selection: selectionRef, newBot: openNewBot)
      }
    }
    .modifier(WorkspaceInspectorPresentation(store: store, selection: selectionRef))
    .modifier(
      WorkspaceChildAgentsEnvironment(store: store, selection: selectionRef, revealRequest: sidebarRevealRequest)
    )
    .overlay {
      AdaptiveDrawerLayer(
        isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
        edge: .leading,
        width: AdaptivePanelLayout.sidebarDrawerWidth
      ) {
        RootSidebar(
          selection: selectionRef, botEditor: $botEditor, store: store, revealRequest: sidebarRevealRequest,
          publishesSceneActions: false,
          isDrawer: true)
      }
    }
  }

  private func detail(_ store: SessionStore) -> some View {
    ZStack {
      WorkspaceDeck(navigation: navigation) { route in
        deckPage(store, route: route)
      }
      .background(WorkspaceChromeHost(navigation: navigation))
      SidebarSelectionReader(selection: selectionRef) { selection in
        transientDetail(store, selection: selection)
      }
    }
  }

  @ViewBuilder
  private func deckPage(_ store: SessionStore, route: WorkspaceDeckRoute) -> some View {
    switch route {
    case let .session(serverId, sessionId):
      sessionDetail(store, serverId: serverId, sessionId: sessionId)
    case let .workspace(serverId, workspaceId):
      workspaceDetail(store, serverId: serverId, workspaceId: workspaceId)
    case let .bot(serverId, botId):
      botDetail(store, serverId: serverId, botId: botId)
    }
  }

  @ViewBuilder
  private func transientDetail(_ store: SessionStore, selection: SidebarSelection?) -> some View {
    switch selection {
    case let .archivedWorkspace(serverId, workspaceId):
      archivedWorkspaceDetail(store, serverId: serverId, workspaceId: workspaceId)
    case let .newChat(target):
      newChat(store, target: target)
    case .none:
      newChat(store, target: nil)
    case .session, .workspace, .bot:
      EmptyView()
    }
  }

  private func sessionDetail(
    _ store: SessionStore,
    serverId: String,
    sessionId: UUID
  ) -> some View {
    SessionRouteView(
      store: store,
      serverId: serverId,
      sessionId: sessionId,
      onFocusedChatChanged: { chatId in
        let chat = environment.projectList.session(chatId, serverId: serverId)
        if let chat, !store.isHostedElsewhere(chat) {
          self.selection = .session(serverId: serverId, id: chatId)
        } else if let workspaceId = environment.workspaces.workspaceId(forSession: sessionId) {
          self.selection = .workspace(serverId: serverId, id: workspaceId)
        }
      },
      onDisposition: { disposition in
        guard selection == .session(serverId: serverId, id: sessionId) else { return }
        applySelectedSessionDisposition(disposition)
      },
      onShownElsewhere: { session in
        guard selection == .session(serverId: serverId, id: sessionId) else { return }
        selection = store.selectChat(session)
      }
    )
  }

  private func workspaceDetail(
    _ store: SessionStore,
    serverId: String,
    workspaceId: UUID
  ) -> some View {
    WorkspaceRouteView(
      store: store,
      serverId: serverId,
      workspaceId: workspaceId,
      onFocusedChatChanged: { chatId in
        guard let chat = environment.projectList.session(chatId, serverId: serverId),
          !store.isHostedElsewhere(chat)
        else { return }
        self.selection = .session(serverId: serverId, id: chatId)
      },
      onMoved: { workspace in
        guard selection == .workspace(serverId: serverId, id: workspaceId) else { return }
        if workspace.isArchived {
          selection = .archivedWorkspace(serverId: workspace.serverId, id: workspace.id)
        } else {
          openRestoredWorkspace(workspace, tabId: nil)
        }
      }
    )
  }

  private func archivedWorkspaceDetail(
    _ store: SessionStore,
    serverId: String,
    workspaceId: UUID
  ) -> some View {
    ArchivedWorkspaceRouteView(
      store: store,
      serverId: serverId,
      workspaceId: workspaceId,
      onRestored: { workspace, tabId in
        guard selection == .archivedWorkspace(serverId: serverId, id: workspaceId) else { return }
        openRestoredWorkspace(workspace, tabId: tabId)
      }
    )
  }

  private func openRestoredWorkspace(_ workspace: Workspace, tabId: UUID?) {
    let fallback = SidebarSelection.workspace(serverId: workspace.serverId, id: workspace.id)
    guard
      let tab = workspace.centerTabs.first(where: { $0.id == tabId })
        ?? workspace.selectedCenterTab ?? workspace.centerTabs.first,
      store?.selectDestination(.tab(tab.id), in: workspace.id) == true
    else {
      selection = fallback
      return
    }
    let route = workspace.selectionRoute(
      activatedChatSessionId: environment.projectList.routableChat(in: tab, serverId: workspace.serverId)?.id,
      routingSessionId: nil,
      selectionAlreadyRoutesWorkspace: false
    )
    switch route {
    case let .session(serverId, id): selection = .session(serverId: serverId, id: id)
    case let .workspace(serverId, id): selection = .workspace(serverId: serverId, id: id)
    case nil: selection = fallback
    }
  }

  private func newChat(_ store: SessionStore, target: NewChatTarget?) -> some View {
    SidebarModeBlankPage(onNewBot: openNewBot) { newChatView(store, target: target) }
  }

  private func newChatView(_ store: SessionStore, target: NewChatTarget?) -> some View {
    NewChatView(
      store: store,
      selection: selectionRef,
      initialProjectTarget: target.flatMap { environment.machines.isSandbox($0.serverId) ? nil : $0 },
      requiresInitialProjectResolution: requiresInitialNewChatProjectResolution,
      onInitialProjectResolutionCompleted: {
        requiresInitialNewChatProjectResolution = false
      }
    )
  }
}

nonisolated enum SidebarSelection: Hashable, Codable, Sendable {
  case session(serverId: String, id: UUID)
  case workspace(serverId: String, id: UUID)
  case archivedWorkspace(serverId: String, id: UUID)
  case bot(serverId: String, id: UUID)
  case newChat(NewChatTarget?)

  var owningMode: SidebarMode? {
    switch self {
    case .bot: .bots
    case .session, .workspace, .archivedWorkspace: .code
    case .newChat: nil
    }
  }
}

nonisolated extension SidebarSelection? {
  var showsNewChat: Bool {
    switch self {
    case .none, .newChat: true
    case .session, .workspace, .archivedWorkspace, .bot: false
    }
  }
}

#Preview("Root") {
  RootView()
    .environment(AppEnvironment.preview())
    .frame(width: 1100, height: 720)
}
