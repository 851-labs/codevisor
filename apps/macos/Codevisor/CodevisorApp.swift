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

struct ClientDataStartupFailureView: View {
  let message: String
  let retry: () -> Void
  let showDataFolder: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Codevisor Couldn't Open Its Data", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text("The app stopped before loading or syncing so your existing data remains intact.\n\n\(message)")
    } actions: {
      HStack {
        Button("Try Again", action: retry)
          .buttonStyle(.borderedProminent)
        Button("Show Data Folder", action: showDataFolder)
      }
    }
    .padding(32)
  }
}

struct RootView: View {
  @Environment(AppEnvironment.self) var environment
  @Environment(\.controlActiveState) var controlActiveState
  @Environment(\.openSettings) var openClientSettings
  @State var clientWindow = ClientWindowControl()
  @State var selection: SidebarSelection?
  @State private var sidebarRevealRequest = SidebarRevealRequest()
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) var sidebarMode
  @State var botEditor: BotEditorTarget?
  @State var store: SessionStore?
  @State private var requiresInitialNewChatProjectResolution = false
  @State var panelLayout = AdaptivePanelLayout()
  @State private var commandPalette = CommandPalette()

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
      .background(RootTitlebar(isBotConversation: showsBotConversation, panelLayout: panelLayout))
      .environment(\.openChat, OpenChatAction { await openChat($0) })
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
      .onChange(of: selection) { _, newValue in
        guard let store else { return }
        if case let .session(serverId, sessionId) = newValue {
          store.markOpened(sessionId, serverId: serverId)
        } else if case let .bot(serverId, botId) = newValue,
          let bot = environment.bots.bot(serverId: serverId, id: botId)
        {
          store.markOpened(bot.sessionId, serverId: serverId)
        } else {
          store.clearOpenSession()
        }
      }
      .task(id: environment.machines.sandboxMachineProfilesLoadKey) {
        await environment.machines.loadSandboxMachineProfiles()
      }
      .onChange(of: botsEnabled) { _, enabled in
        if !enabled, case .bot = selection { selection = .newChat(nil) }
      }
      .onChange(of: controlActiveState, initial: true) { _, state in
        store?.setWindowFocused(state == .key)
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
          created.setWindowFocused(controlActiveState == .key)
          ChromiumAutomationBridge.shared.addStore(created)
        }
        if !AppPreview.isRunning {
          await environment.cloud.bootstrap()
        }
      }
      .modifier(SidebarModeSelectionMemory(selection: $selection) { panelLayout.dismissDrawer() })
      .modifier(UpdateCenterUpkeep())
      .modifier(ConnectionRecoveryUpkeep())
      .modifier(ChromiumBrowserHostSync())
      .modifier(ServerDataUpgradePresentation())
      .modifier(CloudAuthDeeplinkHandling())
  }

  private func openNotificationSession(_ sessionId: UUID, serverId: String) {
    guard let session = environment.projectList.session(sessionId, serverId: serverId) else { return }
    let bot = botsEnabled ? environment.bots.bot(forSession: sessionId, serverId: serverId) : nil
    store?.selectChat(session)
    if let bot {
      selection = .bot(serverId: serverId, id: bot.id)
    } else {
      selection = .session(serverId: serverId, id: sessionId)
    }
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
      selection = .newChat(nil)
    }
  }

  private var mainSplit: some View {
    RootSplitView(store: store) {
      RootSidebar(selection: $selection, botEditor: $botEditor, store: store, revealRequest: sidebarRevealRequest)
    } detail: {
      Group {
        if let store {
          detail(store, selection: selection)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .toolbar { SidebarComposeToolbarItem(newChat: openNewChat, newBot: openNewBot) }
    }
    .modifier(WorkspaceInspectorPresentation(store: store, selection: $selection, revealRequest: sidebarRevealRequest))
    .modifier(WorkspaceChildAgentsEnvironment(store: store, selection: $selection, revealRequest: sidebarRevealRequest))
    .overlay {
      AdaptiveDrawerLayer(
        isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
        edge: .leading,
        width: min(270, panelLayout.windowWidth - 16)
      ) {
        RootSidebar(
          selection: $selection, botEditor: $botEditor, store: store, revealRequest: sidebarRevealRequest,
          publishesSceneActions: false,
          isDrawer: true)
      }
    }
  }

  private func detail(_ store: SessionStore, selection: SidebarSelection?) -> some View {
    ZStack {
      WorkspaceDeck(active: WorkspaceDeckRoute(selection)) { route in
        deckPage(store, route: route)
      }
      transientDetail(store, selection: selection)
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
        self.selection = .session(serverId: serverId, id: chatId)
      },
      onDisposition: { disposition in
        guard selection == .session(serverId: serverId, id: sessionId) else { return }
        applySelectedSessionDisposition(disposition)
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
        self.selection = .session(serverId: serverId, id: chatId)
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
      selection: $selection,
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
    case .bot: .chat
    case .session, .workspace, .archivedWorkspace: .code
    case .newChat: nil
    }
  }
}

#Preview("Root") {
  RootView()
    .environment(AppEnvironment.preview())
    .frame(width: 1100, height: 720)
}
