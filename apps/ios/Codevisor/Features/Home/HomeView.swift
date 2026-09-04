import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// The workspace navigation screen, organized and ordered like the macOS
/// sidebar, with settings at the top left, the organize menu at the top
/// right, and a fixed compose button at the bottom trailing edge.
struct HomeView: View {
  static let newChatTransitionID = "home-new-chat"

  @Environment(AppEnvironment.self) var environment
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  @ClientPreference("sidebar.organization", default: HomeOrganization.compact.rawValue)
  var organizationRaw
  @ClientPreference("sidebar.order", default: HomeOrder.updated.rawValue)
  var orderRaw
  @ClientPreference("sidebar.manualProjectOrder", default: "")
  var manualProjectOrder
  @ClientPreference("sidebar.manualWorkspaceOrder", default: "")
  var manualWorkspaceOrder
  @ClientPreference("sidebar.manualSessionOrder", default: "")
  var manualSessionOrder
  @ClientPreference("sidebar.expandedProjects", default: "")
  var expandedProjectsRaw
  /// View-owned mirror of `expandedProjectsRaw`, seeded on appear. The
  /// disclosure animates off THIS state: toggling straight through the
  /// shared preference store landed in whatever transaction happened to
  /// be current (a tap also flips the touch hold), so the open/close
  /// animation came and went at random.
  @State var expandedProjectIDs: Set<UUID> = []
  @ClientPreference("sidebar.expandedWorkspaces", default: "")
  var expandedWorkspacesRaw
  @ClientPreference("sidebar.showEmptyProjects", default: false)
  var showEmptyProjects
  @ClientPreference("sidebar.showEmptyWorkspaces", default: false)
  var showEmptyWorkspaces
  @ClientPreference("ios.onboarding.dismissed", default: false)
  var onboardingDismissed
  @State var onboardingStart = OnboardingView.Step.welcome
  // Bootstrap adds the dev machine a beat after first render; the grace
  // period keeps onboarding from flashing over an already-paired install.
  @State private var readyForOnboarding = false
  /// First-launch budget: with nothing cached the spinner is allowed,
  /// but it may never outlive the wait — after this it becomes retry.
  @State var initialSyncDeadlineExpired = false
  @State var presentedSettingsDestination: SettingsDestination?
  /// Dismissals apply to this outage; recovery lets a later failure alert again.
  @State var dismissedSyncFailureMachineIDs: Set<String> = []
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
  @State var isPointerInsideSidebar = false
  @GestureState var isTouchingSidebar = false
  /// Group reordering uses a dedicated flat List. The disclosure
  /// preferences remain untouched so returning restores the prior layout.
  @State var groupReorderOrganization: HomeOrganization?
  @State var groupReorderInitialOrder: String?
  @State var deferredSessionOrder = InteractionDeferredOrder<UUID>()
  @State private var orderingCache = HomeSessionOrderingCache()
  /// Non-nil while a burst of automatic reorders is settling (the deferred
  /// order is locked without the user touching or hovering the list).
  @State var reorderSettleHoldStart: Date?
  @State var reorderSettleTask: Task<Void, Never>?
  /// The active hold's pacing: reactive holds commit quickly; the
  /// pre-emptive foreground hold waits out recovery latency and absorbs
  /// the whole catch-up burst into one reflow.
  @State var reorderSettleProfile = ReorderSettleProfile.reactive
  /// True after the scene has been fully backgrounded, so the pre-emptive
  /// settle hold engages only on a genuine re-open (not a control-center
  /// or app-switcher peek that merely passes through `.inactive`).
  @State private var wasBackgrounded = false
  /// The repository is deliberately non-observable. Bump this after a
  /// workspace backfill or local layout mutation so the hierarchy re-reads.
  @State var workspaceRevision = 0
  @Namespace var newChatTransition
  #if DEBUG || NAVIGATION_DIAGNOSTICS
    @State private var didHandleDiagnosticSessionLaunch = false
  #endif

  var organization: HomeOrganization {
    HomeOrganization(rawValue: organizationRaw) ?? .compact
  }

  var order: HomeOrder {
    HomeOrder(rawValue: orderRaw) ?? .updated
  }

  var machines: MachineController { environment.machines }
  var projectList: ProjectListModel { environment.projectList }

  private var hasRemoteMachines: Bool {
    machines.allMachines.contains { !$0.isLocal }
  }

  /// True while no machine has synced and none has failed — the fleet is still converging.
  /// Cached records stay hidden until a current snapshot arrives.
  var initialSyncPending: Bool {
    !anyMachineSynced && failedSyncMachines.isEmpty && hasRemoteMachines
  }

  /// Onboarding presents itself whenever no machine is paired. There is no
  /// in-flow skip (the app is useless without a machine); the dismissed
  /// flag only records programmatic closes — e.g. pairing while the cover
  /// is up — and the empty state re-arms it.
  private var showsOnboarding: Binding<Bool> {
    Binding(
      get: { readyForOnboarding && !onboardingDismissed && !hasRemoteMachines },
      set: { if !$0 { onboardingDismissed = true } }
    )
  }

  /// Active chats from current machines before interaction/settle holds apply.
  /// Watched separately from `visibleSessions` to coalesce automatic reorders
  /// (the held, displayed order does not change while locked).
  private var desiredVisibleSessions: [ChatSession] {
    // Cached chats stay hidden until their machine has a current snapshot.
    let sessions = projectList.sessions.filter {
      !$0.isArchived && currentNavigationMachineIDs.contains($0.serverId)
    }
    let ordered = preferenceIDs(from: manualSessionOrder)
    let manualRanks = Dictionary(
      uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) }
    )
    return orderingCache.sessions(
      sessions,
      order: order,
      manualRanks: manualRanks,
      priority: priority
    )
  }

  /// Active chats from current machines, in the chosen order.
  var visibleSessions: [ChatSession] {
    let desired = desiredVisibleSessions
    guard order != .none else { return desired }
    return deferredSessionOrder.applying(to: desired, id: \.id)
  }

  var body: some View {
    NavigationStack(path: $path) {
      Group {
        if !hasRemoteMachines {
          noMachineState
        } else {
          refreshableNavigationContent
        }
      }
      .onHover { isPointerInsideSidebar = $0 }
      .simultaneousGesture(
        DragGesture(minimumDistance: 0)
          .updating($isTouchingSidebar) { _, isTouching, _ in
            isTouching = true
          }
      )
      .onChange(of: isPointerInsideSidebar || isTouchingSidebar) { _, isInteracting in
        setAutomaticOrderDeferred(isInteracting)
      }
      .onChange(of: visibleSessions.map(\.id)) { _, newIDs in
        deferredSessionOrder.incorporate(newIDs)
        backfillWorkspacesIfNeeded()
      }
      .onAppear {
        expandedProjectIDs = persistedIDs(from: expandedProjectsRaw)
      }
      .onChange(of: failedSyncMachineIDs, initial: true) { _, failedIDs in
        // Recovery re-arms a future failure alert.
        dismissedSyncFailureMachineIDs.formIntersection(failedIDs)
      }
      // Bursty automatic reorders (several agents changing state at
      // once) are jarring. Watching the unheld sort lets a burst land
      // as one animated reflow after it settles.
      .onChange(of: desiredVisibleSessions.map(\.id)) { _, _ in
        scheduleReorderSettleHold()
      }
      // Re-opening the app starts a catch-up that replays every
      // machine's accumulated changes into a visible list. Freeze the
      // order BEFORE that burst arrives so it lands as one reflow —
      // a reactive hold always commits the burst's first change.
      .onChange(of: scenePhase) { _, phase in
        switch phase {
        case .background:
          wasBackgrounded = true
        case .active:
          guard wasBackgrounded else { break }
          wasBackgrounded = false
          beginForegroundSettleHold()
        default:
          break
        }
      }
      .onChange(of: organizationRaw, initial: true) { _, _ in
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
      .onDisappear {
        releaseDeferredOrder(animated: false)
      }
      .navigationTitle(organization.title)
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        if groupReorderOrganization != nil {
          ToolbarItem(placement: .cancellationAction) {
            groupReorderCancelButton
          }
          ToolbarItem(placement: .confirmationAction) {
            groupReorderConfirmButton
          }
        } else {
          // Settings on the left; Home itself is the fleet's, so
          // there is no machine switcher — selection follows the
          // chat you open, and machines are managed in Settings.
          ToolbarItem(placement: .topBarLeading) { settingsButton }
          ToolbarItem(placement: .topBarTrailing) { organizeMenu }
        }
      }
      .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
        if hasRemoteMachines,
          !(visibleSessions.isEmpty && !anyMachineSynced),
          groupReorderOrganization == nil
        {
          newChatButton
        }
      }
      .navigationDestination(for: HomeRoute.self) { route in
        switch route {
        case let .workspace(
          serverId,
          workspaceId,
          anchorSessionId,
          preferredChatSessionId
        ):
          workspaceDestination(
            serverId: serverId,
            workspaceId: workspaceId,
            anchorSessionId: anchorSessionId,
            preferredChatSessionId: preferredChatSessionId
          )
        }
      }
      .alert(syncFailureAlertTitle, isPresented: syncFailureAlertIsPresented) {
        Button("Open Settings") {
          openFailedMachineSettings()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(syncFailureAlertMessage)
      }
      .sheet(item: $presentedSettingsDestination) { destination in
        SettingsSheet(initialDestination: destination)
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
        OnboardingView(start: onboardingStart)
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
      // External entries — codevisor:// deeplinks and notification
      // taps — parsed and routed in one modifier; chat opens (possibly
      // on another machine) come back through these closures.
      .modifier(
        HomeExternalRouting(
          pendingDeeplink: $pendingDeeplink,
          pendingPluginInstall: $pendingPluginInstall,
          openSession: { openNotificationSession($0, serverId: $1) },
          openDiagnosticSession: { id in
            #if DEBUG || NAVIGATION_DIAGNOSTICS
              openDiagnosticSession(id)
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
          if !didHandleDiagnosticSessionLaunch,
            let value = ProcessInfo.processInfo.environment[
              "CODEVISOR_DIAGNOSTIC_SESSION_ID"
            ],
            let id = UUID(uuidString: value)
          {
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
                  // Own this sequence independently of Home's
                  // view task; pushing the first workspace
                  // correctly cancels that view task.
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
                break
              }
              try? await Task.sleep(for: .milliseconds(100))
            }
          }
        #endif
      }
    }
  }
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
