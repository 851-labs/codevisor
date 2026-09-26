import SwiftUI
import AppKit
import CodevisorCore
import CodevisorCoreMac
import QuickLook
import CodevisorUI

struct CodevisorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  /// Started by the app delegate at launch, not by a window (851-2386); a window that appears
  /// first starts it too.
  @State private var runtime = AppRuntime.shared

  var body: some Scene {
    WindowGroup {
      if let environment = runtime.environment {
        RootView()
          .frame(minWidth: 480, minHeight: 600)
          .themedRoot()
          .modifier(DebugMetricsOverlayModifier())
          .environment(environment)
          // Deeplinks (codevisor://add-machine) should land in the
          // window that's already open; without this, macOS spawns a
          // fresh window scene for every external URL event.
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
    // Keep the native zoom target stable while responsive side panels
    // mount and unmount as the window crosses their width thresholds.
    // AppKit still owns saving and restoring the user's previous frame.
    .windowIdealSize(.maximum)
    .commands {
      if let environment = runtime.environment {
        AppUpdateCommands(environment: environment)
        FileCommands()
        MachineCommands(machines: environment.machines)
        WorkspaceLayoutCommands()
        BrowserCommands()
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

/// The top-level split view: collapsible sidebar plus the active session or the
/// new-chat page.
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
  @State private var quickLook = QuickLookController()
  @State var panelLayout = AdaptivePanelLayout()

  var body: some View {
    Group {
      if environment.settings.hasCompletedOnboarding {
        mainSplit
      } else {
        // Resumes where a mid-flow relaunch left off (granting Screen
        // Recording asks for one) instead of restarting the flow.
        OnboardingView(
          initialStep: OnboardingView.resumeStep(from: environment.settings)
        ) { project in
          requiresInitialNewChatProjectResolution = true
          // Land on the new-workspace page (picker) rather than the
          // quick-create fast path — the user should name/configure
          // their first workspace, not get a random one auto-made.
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
    // Locks the composer's submit action while this app installs its own
    // update (it is about to restart).
    .environment(\.isAppUpdateInProgress, environment.isUpdateInProgress)
    // App-level fallback surface for errors with no natural home in the
    // UI (background sync, persistence).
    .overlay { ErrorBannerLayer() }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      panelLayout.updateWindowWidth(width)
    }
    // Keep the selected route out of the controller LRU. Read state is
    // acknowledged separately by the transcript viewport.
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
    // An update arrived and the Computer Use permissions are not set up:
    // ask once per version, as a dialog over the app rather than a
    // takeover. An overlay rather than a sheet — see the gate view; a
    // modal sheet would block the "Quit & Reopen" that granting Screen
    // Recording ends in.
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
          // Computer Use turns off so nothing half-works; the
          // Computer Use toggle in Settings re-enters setup.
          environment.settings.setPermissionsSetupSkipped(true)
          environment.settings.setPermissionsReviewInProgress(false)
          // Per-machine truth: skipping permissions disables
          // Computer Use HERE, never across the fleet.
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
        // A remote client updated this machine's server: the bundled
        // server hands the update back here. Sparkle installs the
        // signed app update and replaces app + bundled server
        // together — unattended, because the person who asked is at
        // ANOTHER machine's screen and nobody here could accept a
        // prompt.
        environment.localServer?.onUpdateRequested = { [environment] in
          Task { @MainActor in
            await environment.appUpdate.installUpdateUnattended()
          }
        }
        // Restore the cloud account session (or adopt the dev cloud
        // token) in the background; nothing at boot depends on it.
        await environment.cloud.bootstrap()
      }
    }
    // Fleet update upkeep: the periodic sweep behind the sidebar footer
    // count and Settings › Updates, and the resume of an update-all the
    // app's own restart interrupted.
    .modifier(UpdateCenterUpkeep())
    // The local server's blocking data upgrade: a non-dismissable sheet
    // over the whole window, wherever the user is, instead of a card only
    // the New Chat page used to show.
    .modifier(ServerDataUpgradePresentation())
    // codevisor://add-machine deeplinks, printed by `codevisor setup` on a
    // remote machine. Extracted into its own modifier: inlining the
    // alerts here pushed this already-large chain past the Swift type
    // checker's budget on release builds.
    .modifier(MachineDeeplinkHandling())
    // codevisor://cloud-auth deeplinks — the browser handoff's fallback
    // path when sign-in ran in the default browser instead of the
    // ASWebAuthenticationSession sheet.
    .modifier(CloudAuthDeeplinkHandling())
    // codevisor://install-plugin deeplinks — the web plugin directory's
    // "Open in Codevisor" button.
    .modifier(PluginInstallDeeplinkHandling())
  }

  private func openNotificationSession(_ sessionId: UUID, serverId: String) {
    guard let session = environment.projectList.session(sessionId, serverId: serverId) else { return }
    store?.selectChat(session)
    selection = .session(serverId: serverId, id: sessionId)
  }

  /// Shared Core policy keeps both native navigation surfaces aligned when
  /// an event archives, unarchives, moves, or removes the current chat. The
  /// chat route computes it when its chat or workspace changes.
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

  /// The top-level split: the NATIVE NavigationSplitView + NSToolbar pair
  /// (Finder's model) — sidebar tracking, the collapse animation, window
  /// dragging, and fullscreen are all system behavior. The pane tab bar is
  /// ordinary content BELOW the toolbar (see SessionContainerView).
  private var mainSplit: some View {
    NavigationSplitView(columnVisibility: sidebarColumnVisibility) {
      // No per-machine remount and no machine switcher: the sidebar is
      // the FLEET's. Selection is a routing detail that follows the
      // chat you open (or send), and machines are managed in Settings.
      SidebarView(selection: $selection, store: store)
        .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        .themedToolbarBackground(theme, role: .sidebar)
    } detail: {
      Group {
        if let store {
          detail(store, selection: selection)
        } else {
          ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .themedToolbarBackground(theme, role: .content)
      // The pane tab bar draws its own bottom divider; a system hairline
      // above it would box the tab strip in between two rules.
      .hidesTitlebarSeparator()
    }
    .overlay {
      AdaptiveDrawerLayer(
        isPresented: !panelLayout.docksSidebar && panelLayout.activeDrawer == .leading,
        edge: .leading,
        width: min(270, panelLayout.windowWidth - 16)
      ) {
        SidebarView(selection: $selection, store: store, publishesSceneActions: false)
          .themedSurface(.sidebar, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
      }
    }
  }

  /// At compact widths the system sidebar remains collapsed and its normal
  /// toggle opens our transient drawer instead. Automatic collapse doesn't
  /// touch the persisted `sidebarCollapsed` preference.
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
        // The route reports for the chat it shows; a stale report from a
        // route being replaced must not act on the new selection.
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

  /// The standalone new-chat page. Creates NOTHING until the first message
  /// is sent — sending resolves the picked directory (project folder or a
  /// fresh worktree) and materializes the workspace around the started
  /// chat. A sidebar per-project button preselects that project.
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

/// Identifies the current sidebar selection.
enum SidebarSelection: Hashable {
  case session(serverId: String, id: UUID)
  /// A workspace shown on its own. Workspaces own their layout and server
  /// identity independently of any chat, so one that has never hosted a chat
  /// is still somewhere the user can be.
  case workspace(serverId: String, id: UUID)
  case newChat(NewChatTarget?)
}

/// A project id is only unique inside one machine snapshot: synced machines
/// deliberately carry the same logical project ids. Navigation therefore
/// keeps the machine and project together instead of guessing from UUID alone.
struct NewChatTarget: Hashable {
  let serverId: String
  let projectId: UUID

  init(serverId: String, projectId: UUID) {
    self.serverId = serverId
    self.projectId = projectId
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
