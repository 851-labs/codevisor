import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The workspace sidebar: every workspace in the fleet as a collapsible
/// section listing its tabs, mirroring the macOS sidebar's layout with
/// settings at the top left, sidebar options at the top right, and a fixed
/// compose button at the bottom trailing edge.
struct HomeView: View {
  static let settingsTransitionID = "home-settings"
  static let newChatTransitionID = "home-new-chat"
  @Namespace var settingsTransition
  @Namespace var newChatTransition

  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.scenePhase) var scenePhase

  @ClientPreference("sidebar.manualWorkspaceOrder", default: "")
  var manualWorkspaceOrder
  @ClientPreference("ios.onboarding.dismissed", default: false)
  var onboardingDismissed
  @ClientPreference(AIDataSharingConsent.preferenceKey, default: 0)
  private var aiDataSharingConsentVersion
  @State var onboardingStart = OnboardingView.Step.welcome
  // Bootstrap adds the dev machine a beat after first render; the grace
  // period keeps onboarding from flashing over an already-paired install.
  @State private var readyForOnboarding = false
  /// First-launch budget: with nothing cached the spinner is allowed,
  /// but it may never outlive the wait — after this it becomes retry.
  @State var initialSyncDeadlineExpired = false
  @State var clientSettingsSection = "root"
  @State var clientPresentationCompletion = ClientPresentationCompletion()
  @State var presentedSettingsDestination: SettingsDestination?
  @State private var pendingHarnessSignIn: HarnessSignInRequest?
  @State var newChatFlow: NewChatFlow?
  /// Presentation and promotion have different lifetimes. SwiftUI owns this
  /// item only while the native sheet exists; `newChatFlow` deliberately
  /// survives its removal until the overlay hands off to Home's real route.
  /// Using the item as the sheet input also guarantees the content closure
  /// is constructed with a non-nil flow on the very first presentation.
  @State var presentedNewChatFlow: NewChatFlow?
  @State var newChatSheetPath = NavigationPath()
  // A typed path lets Home identify the workspace currently presented and
  // pop it when a remote server refresh archives that chat.
  @State var path: [HomeRoute] = []
  @State private var pendingDeeplink: MachineDeeplink?
  @State private var deeplinkError: String?
  /// A codevisor://install-plugin deeplink (the web plugin directory's
  /// "Open in Codevisor" button), staged until the install sheet presents.
  @State private var pendingPluginInstall: PendingPluginInstall?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingTab: HomeTabRenameRequest?
  @State var tabRenameTitle = ""
  /// The repository is deliberately non-observable. Bump this after a
  /// workspace backfill or local layout mutation so the hierarchy re-reads.
  @State var workspaceRevision = 0
  #if DEBUG || NAVIGATION_DIAGNOSTICS
    @State private var didHandleDiagnosticSessionLaunch = false
    @State private var didHandleDiagnosticNewChatLaunch = false
  #endif

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

  private var hasRemoteMachines: Bool {
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
  private var showsOnboarding: Binding<Bool> {
    Binding(
      get: {
        readyForOnboarding && !showsSampleSidebar && presentedSettingsDestination == nil
          && (!hasAIDataSharingConsent || (!onboardingDismissed && !hasRemoteMachines))
      },
      set: { if !$0 && hasAIDataSharingConsent { onboardingDismissed = true } }
    )
  }

  private var hasAIDataSharingConsent: Bool {
    aiDataSharingConsentVersion == AIDataSharingConsent.currentVersion
  }

  private var showsNewChatButton: Bool {
    if showsSampleSidebar { return true }
    guard hasAIDataSharingConsent else { return false }
    return hasRemoteMachines && !(sidebarSections.isEmpty && !anyMachineSynced)
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if showsSampleSidebar {
          #if DEBUG
            sampleSidebar
          #endif
        } else if !hasRemoteMachines {
          noMachineState
        } else {
          refreshableNavigationContent
        }
      }
      .onChange(of: activeSessions.map(\.id), initial: true) { _, _ in
        backfillWorkspacesIfNeeded()
      }
      .onChange(of: path, initial: true) { oldPath, newPath in
        IOSNavigationDiagnostics.record(
          "home.path",
          "old=\(navigationPathSummary(oldPath)) new=\(navigationPathSummary(newPath))"
        )
      }
      .onChange(of: presentedWorkspaceDisposition, initial: true) { _, disposition in
        applyPresentedWorkspaceDisposition(disposition)
      }
      // No title: the workspace headers are the page's headings, and the
      // bar keeps only its two buttons. The pushed workspace's back button
      // falls back to the system "Back" label.
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        // Settings on the left; Home itself is the fleet's, so there is
        // no machine switcher — selection follows the chat you open, and
        // machines are managed in Settings.
        ToolbarItem(placement: .topBarLeading) { settingsButton }
          .matchedTransitionSource(id: Self.settingsTransitionID, in: settingsTransition)
        if !failedSyncMachines.isEmpty {
          ToolbarItem(placement: .topBarLeading) {
            machineConnectionWarningButton
          }
        }
        if showsNewChatButton {
          ToolbarSpacer(.flexible, placement: .bottomBar)
          ToolbarItem(placement: .bottomBar) { newChatButton }
            .matchedTransitionSource(id: Self.newChatTransitionID, in: newChatTransition)
        }
      }
      .navigationDestination(for: HomeRoute.self) { route in
        switch route {
        case let .workspace(
          serverId,
          workspaceId,
          anchorSessionId,
          preferredChatSessionId,
          preferredPaneId
        ):
          workspaceDestination(
            serverId: serverId,
            workspaceId: workspaceId,
            anchorSessionId: anchorSessionId,
            preferredChatSessionId: preferredChatSessionId,
            preferredPaneId: preferredPaneId
          )
        }
      }
      .modifier(
        HomeSidebarAlerts(
          renamingWorkspace: $renamingWorkspace,
          workspaceRenameTitle: $workspaceRenameTitle,
          renamingTab: $renamingTab,
          tabRenameTitle: $tabRenameTitle,
          onRenameWorkspace: { renameWorkspace($0) },
          onRenameTab: { renameSidebarTab($0, to: $1) }
        )
      )
      .sheet(item: $presentedSettingsDestination, onDismiss: { clientPresentationCompletion.complete("settings") }) {
        destination in
        SettingsSheet(initialDestination: destination, onSectionChange: { clientSettingsSection = $0 })
          .id(destination.id)
          .navigationTransition(.zoom(sourceID: Self.settingsTransitionID, in: settingsTransition))
      }
      .onReceive(NotificationCenter.default.publisher(for: .codevisorOpenSettings)) { _ in
        presentedSettingsDestination = .root
      }
      .harnessSignInSheet(request: $pendingHarnessSignIn)
      .onReceive(NotificationCenter.default.publisher(for: .codevisorHarnessSignIn)) {
        notification in
        pendingHarnessSignIn = HarnessSignInRequest(notification: notification)
      }
      .sheet(item: $presentedNewChatFlow, onDismiss: handleNewChatSheetDismissed) {
        flow in
        newChatSheet(flow)
      }
      .fullScreenCover(isPresented: showsOnboarding) {
        onboardingStart = .welcome
      } content: {
        OnboardingView(start: hasRemoteMachines || onboardingDismissed ? .connect : onboardingStart)
          .interactiveDismissDisabled(!hasAIDataSharingConsent)
          // The QR flow lands here: alerts must present over the
          // cover, so it carries its own copy of the deeplink
          // alerts, active while it is the visible context.
          .modifier(
            MachineDeeplinkAlerts(
              pending: $pendingDeeplink,
              error: $deeplinkError,
              isActive: true
            )
          )
      }
      // Parse and route codevisor:// deeplinks in one modifier;
      // diagnostic chat opens come back through these closures.
      .modifier(
        HomeExternalRouting(
          pendingDeeplink: $pendingDeeplink,
          pendingPluginInstall: $pendingPluginInstall,
          openDiagnosticSession: { id in
            #if DEBUG || NAVIGATION_DIAGNOSTICS
              openDiagnosticSession(id)
            #endif
          },
          openDiagnosticNewChat: { text in
            #if DEBUG || NAVIGATION_DIAGNOSTICS
              presentDiagnosticNewChat(text: text)
            #endif
          }
        )
      )
      .modifier(
        MachineDeeplinkAlerts(
          pending: $pendingDeeplink,
          error: $deeplinkError,
          isActive: !showsOnboarding.wrappedValue
        )
      )
      .task {
        try? await Task.sleep(for: .milliseconds(300))
        readyForOnboarding = true
        #if DEBUG || NAVIGATION_DIAGNOSTICS
          await handleDiagnosticSessionLaunchIfNeeded()
          await handleDiagnosticNewChatLaunchIfNeeded()
        #endif
      }
    }
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
    private func handleDiagnosticNewChatLaunchIfNeeded() async {
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
    private func handleDiagnosticSessionLaunchIfNeeded() async {
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
