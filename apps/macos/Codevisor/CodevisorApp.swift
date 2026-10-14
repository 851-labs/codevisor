import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import QuickLook
import CodevisorUI

struct CodevisorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var runtime = AppRuntime.shared

  var body: some Scene {
    WindowGroup {
      if let environment = runtime.environment {
        RootView()
          .frame(minWidth: 480, minHeight: 600)
          .themedRoot()
          .modifier(DebugMetricsOverlayModifier())
          .environment(environment)
          .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
      } else if let startupError = runtime.startupError {
        ClientDataStartupFailureView(
          message: startupError,
          retry: runtime.retry,
          showDataFolder: {
            NSWorkspace.shared.activateFileViewerSelecting([
              CodevisorAppVariant.applicationSupportURL()
            ])
          }
        )
        .frame(minWidth: 480, minHeight: 600)
      } else {
        ClientDataStartupView()
          .frame(minWidth: 480, minHeight: 600)
          .task { await runtime.startIfNeeded() }
      }
    }
    .defaultSize(width: 1280, height: 820)
    .windowResizability(.contentMinSize)
    .windowIdealSize(.maximum)
    .commands {
      if let environment = runtime.environment {
        AppUpdateCommands(environment: environment)
        FileCommands()
        WorkspaceLayoutCommands()
        BrowserCommands()
        SimulatorCommands()
        DebugOverlayCommands()
      }
    }

    Settings {
      if let environment = runtime.environment {
        SettingsView()
          .themedRoot()
          .environment(environment)
      } else if let startupError = runtime.startupError {
        ClientDataStartupFailureView(
          message: startupError,
          retry: runtime.retry,
          showDataFolder: {
            NSWorkspace.shared.activateFileViewerSelecting([
              CodevisorAppVariant.applicationSupportURL()
            ])
          }
        )
      } else {
        ClientDataStartupView()
          .task { await runtime.startIfNeeded() }
      }
    }
  }

}

private struct ClientDataStartupFailureView: View {
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
  @Environment(\.theme) private var theme
  @Environment(\.controlActiveState) var controlActiveState
  @Environment(\.openSettings) var openClientSettings
  @State var clientWindow = ClientWindowControl()
  @State var selection: SidebarSelection?
  @ClientPreference("sidebar.collapsed", default: false) var sidebarCollapsed
  @State var store: SessionStore?
  @State private var requiresInitialNewChatProjectResolution = false
  @State private var quickLook = QuickLookController.withAlerts()
  @State var panelLayout = AdaptivePanelLayout()

  var body: some View {
    Group {
      if environment.settings.hasCompletedOnboarding {
        mainSplit
      } else {
        OnboardingView(
          initialStep: OnboardingView.resumeStep(from: environment.settings)
        ) { project in
          requiresInitialNewChatProjectResolution = true
          selection = .newChat(project.map { NewChatTarget($0) })
        }
      }
    }
    .environment(panelLayout)
    .modifier(
      ClientControlModifier(
        name: Host.current().localizedName ?? "Codevisor Mac", platform: "macos",
        context: clientControlContext, navigate: navigateClient, control: controlClient
      )
    )
    .background(ClientWindowReader(control: clientWindow).frame(width: 0, height: 0))
    .environment(\.quickLook, quickLook)
    .quickLookPreview(
      Binding(
        get: { quickLook.previewURL },
        set: { quickLook.updatePreviewURL($0) }
      )
    )
    .environment(\.isAppUpdateInProgress, environment.isUpdateInProgress)
    .overlay { ErrorBannerLayer() }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      panelLayout.updateWindowWidth(width)
    }
    .onChange(of: selection) { _, newValue in
      panelLayout.dismissDrawer(.leading)
      guard let store else { return }
      if case let .session(serverId, sessionId) = newValue {
        store.markOpened(sessionId, serverId: serverId)
      } else {
        store.clearOpenSession()
      }
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
    .task { await reconcileSkippedPermissions(environment: environment) }
    .overlay {
      if environment.requiresPermissionsReview {
        ComputerUsePermissionsGateView {
          environment.settings.setPermissionsReviewedVersion(
            AppUpdateModel.bundleVersion()
          )
          environment.settings.setPermissionsSetupSkipped(false)
          environment.settings.setPermissionsReviewInProgress(false)
          environment.requiresPermissionsReview = false
        } onSkip: {
          environment.settings.setPermissionsSetupSkipped(true)
          environment.settings.setPermissionsReviewInProgress(false)
          Task {
            await McpFleet.disableLocally(
              environment.configSync,
              machines: environment.machines,
              name: "Computer Use"
            )
          }
          environment.requiresPermissionsReview = false
        }
        .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.2), value: environment.requiresPermissionsReview)
    .task {
      if store == nil {
        store = SessionStore(environment: environment)
        store?.setWindowFocused(controlActiveState == .key)
      }
      if !AppPreview.isRunning {
        environment.localServer?.onUpdateRequested = { [environment] in
          Task { @MainActor in
            await environment.appUpdate.installUpdateUnattended()
          }
        }
        await environment.cloud.bootstrap()
      }
    }
    .modifier(UpdateCenterUpkeep())
    .modifier(ServerDataUpgradePresentation())
    .modifier(CloudAuthDeeplinkHandling())
    .modifier(PluginInstallDeeplinkHandling())
  }

  private func openNotificationSession(_ sessionId: UUID, serverId: String) {
    guard let session = environment.projectList.session(sessionId, serverId: serverId) else { return }
    store?.selectChat(session)
    selection = .session(serverId: serverId, id: sessionId)
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
    NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
      WorkspaceSidebar(selection: $selection, store: store)
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
    } detail: {
      Group {
        if let store {
          detail(store, selection: selection)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .themedToolbarBackground(theme)
    }
    .overlay {
      AdaptiveDrawerLayer(
        isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
        edge: .leading,
        width: min(270, panelLayout.windowWidth - 16)
      ) {
        WorkspaceSidebar(selection: $selection, store: store, publishesSceneActions: false)
          .themedSurface(.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
      }
    }
    .onChange(of: clientSidebarVisible, initial: true) { _, visible in
      store?.isSidebarVisible = visible
    }
    .onChange(of: store.map(ObjectIdentifier.init)) { _, _ in
      store?.isSidebarVisible = clientSidebarVisible
    }
  }

  private var sidebarColumnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
      get: {
        panelLayout.docksSidebar && !sidebarCollapsed ? .all : .detailOnly
      },
      set: { visibility in
        if panelLayout.docksSidebar {
          sidebarCollapsed = visibility == .detailOnly
        } else if visibility != .detailOnly {
          panelLayout.toggleDrawer(.leading)
        }
      }
    )
  }

  @ViewBuilder
  private func detail(_ store: SessionStore, selection: SidebarSelection?) -> some View {
    switch selection {
    case let .session(serverId, sessionId):
      sessionDetail(store, serverId: serverId, sessionId: sessionId)
    case let .workspace(serverId, workspaceId):
      workspaceDetail(store, serverId: serverId, workspaceId: workspaceId)
    case let .archivedWorkspace(serverId, workspaceId):
      archivedWorkspaceDetail(store, serverId: serverId, workspaceId: workspaceId)
    case let .newChat(target):
      newChat(store, target: target)
    case .none:
      newChat(store, target: nil)
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
    NewChatView(
      store: store,
      selection: $selection,
      initialProjectTarget: target,
      requiresInitialProjectResolution: requiresInitialNewChatProjectResolution,
      onInitialProjectResolutionCompleted: {
        requiresInitialNewChatProjectResolution = false
      }
    )
  }
}

enum SidebarSelection: Hashable {
  case session(serverId: String, id: UUID)
  case workspace(serverId: String, id: UUID)
  case archivedWorkspace(serverId: String, id: UUID)
  case newChat(NewChatTarget?)
}

struct NewChatTarget: Hashable {
  let serverId: String
  let projectId: UUID?

  init(serverId: String, projectId: UUID?) {
    self.serverId = serverId
    self.projectId = projectId
  }

  init(machine serverId: String) {
    self.init(serverId: serverId, projectId: nil)
  }

  init(_ project: Project) {
    self.init(serverId: project.serverId, projectId: project.id)
  }
}

#Preview("Root") {
  RootView()
    .environment(AppEnvironment.preview())
    .frame(width: 1100, height: 720)
}
