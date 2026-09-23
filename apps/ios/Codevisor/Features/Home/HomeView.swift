import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The workspace sidebar: every workspace in the fleet as a collapsible
/// section listing its tabs, mirroring the macOS sidebar's layout with
/// settings at the top left, sidebar options at the top right, and a fixed
/// compose button at the bottom trailing edge.
struct HomeView: View {
  static let newChatTransitionID = "home-new-chat"
  @Namespace var newChatTransition

  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.scenePhase) var scenePhase
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @Environment(\.openWindow) var openWindow

  @ClientPreference("ios.onboarding.dismissed", default: false)
  var onboardingDismissed
  @ClientPreference(AIDataSharingConsent.preferenceKey, default: 0)
  private var aiDataSharingConsentVersion
  @State var onboardingStart = OnboardingView.Step.welcome
  // Bootstrap adds the dev machine a beat after first render; the grace
  // period keeps onboarding from flashing over an already-paired install.
  @State var readyForOnboarding = false
  /// First-launch budget: with nothing cached the spinner is allowed,
  /// but it may never outlive the wait — after this it becomes retry.
  @State var initialSyncDeadlineExpired = false
  @State var clientSettingsSection = "root"
  @State var clientPresentationCompletion = ClientPresentationCompletion()
  @State var presentedSettingsDestination: SettingsDestination?
  @State var pendingHarnessSignIn: HarnessSignInRequest?
  @State var newChatFlow: NewChatFlow?
  /// Presentation and promotion have different lifetimes. SwiftUI owns this
  /// item only while the native sheet exists; `newChatFlow` deliberately
  /// survives its removal until the overlay hands off to Home's real route.
  /// Using the item as the sheet input also guarantees the content closure
  /// is constructed with a non-nil flow on the very first presentation.
  @State var presentedNewChatFlow: NewChatFlow?
  @State var newChatSheetPath = NavigationPath()
  /// The New Chat sheet's composer is being touched or is fully expanded;
  /// its drags belong to the composer, so the sheet can't be swiped away.
  @State var newChatComposerBlocksDismiss = false
  /// One navigation truth for both containers: the compact stack's path,
  /// and the split detail selection (its last entry). A typed path lets
  /// Home identify the workspace currently presented and pop it when a
  /// remote server refresh archives that chat.
  @State var navigation = HomeNavigationState()
  /// Which container is mounted, latched from the horizontal size class.
  @State var layoutMode: HomeLayoutMode = .stack
  /// The hosting bar has moved its items into iPhone Duo's side strip.
  @State var barsAreVertical = false
  /// A sidebar tap the workspace has not recorded as its selection yet, so
  /// the highlight lands on the tapped row without flicking back first.
  @State var pendingSidebarSelection: UUID?
  /// The split view's column visibility. `.doubleColumn` is the two-column
  /// default; driving it lets a selection dismiss an overlay sidebar.
  @State var sidebarColumnVisibility: NavigationSplitViewVisibility = .doubleColumn
  /// Where the detail column starts: a tiled sidebar pushes it in, an
  /// overlay sidebar (portrait, laptop pose) floats above it at zero.
  @State var detailLeadingInset: CGFloat = 0
  /// A selection dismissed an overlay sidebar, so widening into a tiled
  /// layout (rotating to landscape) should bring the sidebar back.
  @State var sidebarAutoCollapsed = false
  /// The split container's last width, to tell widening from narrowing.
  @State var splitContainerWidth: CGFloat = 0
  /// A size-class change that arrived mid-promotion, applied once it ends.
  @State var pendingLayoutMode: HomeLayoutMode?
  /// The session a detail draft was promoted into; keeps its identity.
  @State var promotedDraftSessionId: UUID?
  /// Bumped when Home enters New Chat afresh so the draft remounts.
  @State var draftGeneration = UUID()
  /// One-shot keyboard focus for the detail draft after a layout swap.
  @State var detailComposerFocusRequest: UUID?
  /// The workspace route a detail draft's first send produced, applied once
  /// the send animation lands so the chrome swap cannot cut it short.
  @State var pendingDraftPromotion: HomeRoute?
  /// Pages pushed within the split detail (a pane's sub-navigation).
  @State var detailPath = NavigationPath()
  @State var pendingDeeplink: MachineDeeplink?
  @State var deeplinkError: String?
  /// A codevisor://install-plugin deeplink (the web plugin directory's
  /// "Open in Codevisor" button), staged until the install sheet presents.
  @State var pendingPluginInstall: PendingPluginInstall?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingTab: HomeTabRenameRequest?
  @State var tabRenameTitle = ""
  /// The repository is deliberately non-observable. Bump this after a
  /// workspace backfill or local layout mutation so the hierarchy re-reads.
  @State var workspaceRevision = 0
  /// The window hosting this Home. With several iPad windows open, only the
  /// one the user is working in answers app-wide presentation requests.
  @State var hostWindow = WeakWindow()
  #if DEBUG || NAVIGATION_DIAGNOSTICS
    @State private var didHandleDiagnosticSessionLaunch = false
    @State private var didHandleDiagnosticNewChatLaunch = false
  #endif

  /// A window opened on one tab (iPad's Open in New Window) starts there.
  init(initialRoute: HomeRoute? = nil) {
    if let initialRoute {
      _navigation = State(initialValue: HomeNavigationState(path: [initialRoute]))
    }
  }

  /// The stack path, proxied so route helpers read and write one value.
  var path: [HomeRoute] {
    get { navigation.path }
    nonmutating set { navigation.path = newValue }
  }

  /// Opening pushes on the compact stack and replaces the split detail.
  func openRoute(_ route: HomeRoute) {
    navigation.open(route, mode: layoutMode)
  }

  var machines: MachineController { environment.machines }
  var projectList: ProjectListModel { environment.projectList }

  var clientBlockingPresentation: String? {
    if showsOnboarding.wrappedValue { return "onboarding" }
    if pendingHarnessSignIn != nil { return "harness_sign_in" }
    if pendingPluginInstall != nil { return "plugin_install" }
    if pendingDeeplink != nil || deeplinkError != nil { return "machine_connection" }
    if renamingWorkspace != nil || renamingTab != nil { return "rename" }
    return nil
  }

  var hasRemoteMachines: Bool {
    machines.allMachines.contains { !$0.isLocal }
  }

  /// Debug builds can stand in a fixture sidebar for design review.
  var showsSampleSidebar: Bool {
    #if DEBUG
      HomeSidebarSampleData.isEnabled
    #else
      false
    #endif
  }

  /// True while no machine has synced and none has failed — the fleet is still converging.
  /// Cached records stay hidden until a current snapshot arrives.
  var initialSyncPending: Bool {
    !anyMachineSynced && failedSyncMachines.isEmpty && hasRemoteMachines
  }

  /// Consent is required even for an existing installation with paired machines.
  /// After consent, onboarding stays open until a machine is paired; the empty
  /// state can reopen it later.
  var showsOnboarding: Binding<Bool> {
    Binding(
      get: {
        readyForOnboarding && !showsSampleSidebar && presentedSettingsDestination == nil
          && (!hasAIDataSharingConsent || (!onboardingDismissed && !hasRemoteMachines))
      },
      set: { if !$0 && hasAIDataSharingConsent { onboardingDismissed = true } }
    )
  }

  var hasAIDataSharingConsent: Bool {
    aiDataSharingConsentVersion == AIDataSharingConsent.currentVersion
  }

  var showsNewChatButton: Bool {
    if showsSampleSidebar { return true }
    guard hasAIDataSharingConsent else { return false }
    return hasRemoteMachines && !(sidebarSections.isEmpty && !anyMachineSynced)
  }

  var body: some View {
    hoistedPresentations(
      Group {
        switch layoutMode {
        case .stack: stackContainer
        case .split: splitContainer
        }
      }
      // Folding and unfolding iPhone Duo changes the size class, never
      // the orientation; the container follows the width alone.
      .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
        applyLayoutMode(for: sizeClass)
      }
      .onChange(of: newChatFlow?.id) { _, flowId in
        guard flowId == nil, let pending = pendingLayoutMode else { return }
        commitLayoutMode(pending)
      }
      .onChange(of: activeSessions.map(\.id), initial: true) { _, _ in
        backfillWorkspacesIfNeeded()
      }
      .onChange(of: navigation.path, initial: true) { oldPath, newPath in
        IOSNavigationDiagnostics.record(
          "home.path",
          "old=\(navigationPathSummary(oldPath)) new=\(navigationPathSummary(newPath))"
        )
      }
      .onChange(of: presentedWorkspaceDisposition, initial: true) { _, disposition in
        applyPresentedWorkspaceDisposition(disposition)
      }
    )
    .environment(\.homeLayoutMode, layoutMode)
    .environment(\.homeSidebarIsTiled, layoutMode == .split && detailLeadingInset > 1)
    .focusedSceneValue(\.homeCommandActions, homeCommandActions)
    .background(HostWindowReader { hostWindow.window = $0 })
    .modifier(
      ClientControlModifier(
        name: UIDevice.current.name, platform: "ios",
        context: clientControlContext, navigate: navigateClient, control: controlClient
      )
    )
  }

  #if DEBUG || NAVIGATION_DIAGNOSTICS
    /// `CODEVISOR_DIAGNOSTIC_NEW_CHAT_TEXT` presents the New Chat sheet once
    /// a machine has synced, types the text, and — after
    /// `CODEVISOR_DIAGNOSTIC_NEW_CHAT_SEND_DELAY_MS` (default 4000) — taps
    /// send through the composer's real button path. Custom-scheme
    /// deeplinks can't do this headlessly: the system confirms them.
    func handleDiagnosticNewChatLaunchIfNeeded() async {
      let environmentValues = ProcessInfo.processInfo.environment
      guard !didHandleDiagnosticNewChatLaunch,
        let text = environmentValues["CODEVISOR_DIAGNOSTIC_NEW_CHAT_TEXT"], !text.isEmpty
      else { return }
      // Once per process: Home reappears after every promotion, and a
      // second autostart would hijack the user's session.
      didHandleDiagnosticNewChatLaunch = true
      let delay =
        environmentValues["CODEVISOR_DIAGNOSTIC_NEW_CHAT_SEND_DELAY_MS"].flatMap(Int.init) ?? 4000
      for _ in 0..<200 {
        if hasRemoteMachines, anyMachineSynced,
          case .ready = machines.availability(for: environment.defaultComposerServerId)
        {
          break
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      IOSNavigationDiagnostics.record(
        "diag.newChat.launch",
        "chars=\(text.count) delayMs=\(delay) availability=\(machines.availability(for: environment.defaultComposerServerId))"
      )
      presentDiagnosticNewChat(text: text)
      try? await Task.sleep(for: .milliseconds(delay))
      IOSNavigationDiagnostics.record("diag.newChat.autoSend")
      NotificationCenter.default.post(name: .codevisorDiagnosticSubmitComposer, object: nil)
    }

    /// `CODEVISOR_DIAGNOSTIC_SESSION_ID` opens a persisted chat at launch
    /// (and optionally a follow-up) without desktop automation.
    func handleDiagnosticSessionLaunchIfNeeded() async {
      guard !didHandleDiagnosticSessionLaunch,
        let value = ProcessInfo.processInfo.environment["CODEVISOR_DIAGNOSTIC_SESSION_ID"],
        let id = UUID(uuidString: value)
      else { return }
      didHandleDiagnosticSessionLaunch = true
      for _ in 0..<50 {
        if let session = projectList.sessions.first(where: {
          $0.serverId == environment.defaultComposerServerId && $0.id == id
        }) {
          IOSNavigationDiagnostics.record(
            "home.diagnosticLaunchSession",
            "session=\(shortID(id))"
          )
          if let followupValue = ProcessInfo.processInfo.environment[
            "CODEVISOR_DIAGNOSTIC_FOLLOWUP_SESSION_ID"
          ],
            let followupID = UUID(uuidString: followupValue)
          {
            // Own this sequence independently of Home's view task;
            // pushing the first workspace correctly cancels that task.
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(4))
              path.removeAll()
              try? await Task.sleep(for: .milliseconds(750))
              if let followup = projectList.sessions.first(where: {
                $0.serverId == environment.defaultComposerServerId
                  && $0.id == followupID
              }) {
                IOSNavigationDiagnostics.record(
                  "home.diagnosticFollowupSession",
                  "session=\(shortID(followupID))"
                )
                openChat(followup)
              }
            }
          }
          openChat(session)
          return
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  #endif
}

/// Sheet-presentation wrapper for a parsed install-plugin deeplink: the repo
/// is the identity, so a second tap on the same link while the sheet is up
/// doesn't re-present it.
struct PendingPluginInstall: Identifiable {
  let repo: String
  var id: String { repo }
}

#Preview {
  HomeView()
    .environment(AppEnvironment.preview())
}
