import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

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
  @State var readyForOnboarding = false
  @State var clientSettingsSection = "root"
  @State var clientPresentationCompletion = ClientPresentationCompletion()
  @State var presentedSettingsDestination: SettingsDestination?
  @State var pendingHarnessSignIn: HarnessSignInRequest?
  @State var newChatFlow: NewChatFlow?
  @State var presentedNewChatFlow: NewChatFlow?
  @State var newChatSheetPath = NavigationPath()
  @State var newChatComposerBlocksDismiss = false
  @State var navigation = HomeNavigationState()
  @State var layoutMode: HomeLayoutMode = .stack
  @State var barsAreVertical = false
  @State var sidebarColumnVisibility: NavigationSplitViewVisibility = .doubleColumn
  @State var detailLeadingInset: CGFloat = 0
  @State var sidebarAutoCollapsed = false
  @State var splitContainerWidth: CGFloat = 0
  @State var pendingLayoutMode: HomeLayoutMode?
  @State var promotedDraftSessionId: UUID?
  @State var draftGeneration = UUID()
  @State var detailComposerFocusRequest: UUID?
  @State var pendingDraftPromotion: HomeRoute?
  @State var detailPath = NavigationPath()
  @State var pendingDeviceApproval: CloudDeviceApprovalRequest?
  @State var pendingPluginInstall: PendingPluginInstall?
  @State var botEditor: BotEditorTarget?
  @State var botHeaderWindowBottom: CGFloat = 0
  @State var deletingBot: Bot?
  @State var renamingWorkspace: Workspace?
  @State var workspaceRenameTitle = ""
  @State var renamingTab: HomeTabRenameRequest?
  @State var tabRenameTitle = ""
  @State var sidebarActionHandler = HomeSidebarActionHandler(HomeSidebarActions())
  @State var sidebarGitLookups = SidebarGitLookups()
  @ClientPreference(SidebarPreferenceKey.pinnedWorkspaces, default: []) var pinnedWorkspaceIDs: [String]
  @State var navigationPresentation: HomeNavigationPresentation?
  @State var hostWindow = WeakWindow()
  #if DEBUG || NAVIGATION_DIAGNOSTICS
    @State private var didHandleDiagnosticSessionLaunch = false
    @State private var didHandleDiagnosticNewChatLaunch = false
  #endif

  init(initialRoute: HomeRoute? = nil) {
    if let initialRoute {
      _navigation = State(initialValue: HomeNavigationState(path: [initialRoute]))
    }
  }

  var path: [HomeRoute] {
    get { navigation.path }
    nonmutating set { navigation.path = newValue }
  }

  func openRoute(_ route: HomeRoute) {
    navigation.open(route, mode: layoutMode)
  }

  var machines: MachineController { environment.machines }
  var projectList: ProjectListModel { environment.projectList }

  var clientPresentation: String? {
    if presentedSettingsDestination != nil { return "settings" }
    return presentedNewChatFlow == nil ? nil : "new_chat"
  }

  var clientBlockingPresentation: String? {
    if showsOnboarding.wrappedValue { return "onboarding" }
    if pendingHarnessSignIn != nil { return "harness_sign_in" }
    if pendingPluginInstall != nil { return "plugin_install" }
    if pendingDeviceApproval != nil { return "device_approval" }
    if renamingWorkspace != nil || renamingTab != nil { return "rename" }
    if botEditor != nil { return "bot_editor" }
    return nil
  }

  var hasRemoteMachines: Bool {
    machines.allMachines.contains { !$0.isLocal }
  }

  var showsSampleSidebar: Bool {
    #if DEBUG
      HomeSidebarSampleData.isEnabled
    #else
      false
    #endif
  }

  var showsOnboarding: Binding<Bool> {
    Binding(
      get: {
        if let pendingDeviceApproval { return pendingDeviceApproval.presentsOverOnboarding }
        return readyForOnboarding && environment.navigationRosterStatus != .unverified
          && !showsSampleSidebar && presentedSettingsDestination == nil
          && (!hasAIDataSharingConsent || needsLocalNetworkStep || (!onboardingDismissed && !hasRemoteMachines))
      },
      set: { if !$0 && hasAIDataSharingConsent { onboardingDismissed = true } }
    )
  }

  var needsLocalNetworkStep: Bool {
    environment.cloud.state.isSignedIn && environment.needsLocalNetworkChoice
  }

  var hasAIDataSharingConsent: Bool {
    aiDataSharingConsentVersion == AIDataSharingConsent.currentVersion
  }

  var showsNewChatButton: Bool {
    if showsSampleSidebar { return true }
    guard hasAIDataSharingConsent else { return false }
    return hasRemoteMachines && launch != .loading
  }

  var body: some View {
    hoistedPresentations(
      Group {
        switch layoutMode {
        case .stack: stackContainer
        case .split: splitContainer
        }
      }
      .onChange(of: horizontalSizeClass, initial: true) { _, sizeClass in
        applyLayoutMode(for: sizeClass)
      }
      .onChange(of: newChatFlow?.id) { _, flowId in
        guard flowId == nil, let pending = pendingLayoutMode else { return }
        commitLayoutMode(pending)
      }
      .onChange(of: navigation.path, initial: true) { oldPath, newPath in
        IOSNavigationDiagnostics.record(
          "home.path",
          "old=\(navigationPathSummary(oldPath)) new=\(navigationPathSummary(newPath))"
        )
      }
      .background {
        HomePresentedWorkspaceObserver(route: navigation.selection) { disposition in
          applyPresentedWorkspaceDisposition(disposition)
        }
        HomeNavigationPresentationObserver { presentation in
          navigationPresentation = presentation
        }
      }
    )
    .environment(\.homeLayoutMode, layoutMode)
    .environment(\.homeSidebarIsTiled, layoutMode == .split && detailLeadingInset > 1)
    .focusedSceneValue(\.homeCommandActions, homeCommandActions)
    .background(HostWindowReader { hostWindow.window = $0 })
    #if DEBUG
      .task { if AppStoreScreenshotData.opensNewChat { presentNewChat() } }
    #endif
    .modifier(
      ClientControlModifier(
        name: UIDevice.current.name, platform: "ios",
        context: clientControlContext, navigate: navigateClient, control: controlClient
      )
    )
  }

  #if DEBUG || NAVIGATION_DIAGNOSTICS
    func handleDiagnosticNewChatLaunchIfNeeded() async {
      let environmentValues = ProcessInfo.processInfo.environment
      guard !didHandleDiagnosticNewChatLaunch,
        let text = environmentValues["CODEVISOR_DIAGNOSTIC_NEW_CHAT_TEXT"], !text.isEmpty
      else { return }
      didHandleDiagnosticNewChatLaunch = true
      let delay =
        environmentValues["CODEVISOR_DIAGNOSTIC_NEW_CHAT_SEND_DELAY_MS"].flatMap(Int.init) ?? 4000
      for _ in 0..<200 {
        if hasRemoteMachines, machines.navigationSyncStateByMachineId.values.contains(.current),
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

struct PendingPluginInstall: Identifiable {
  let repo: String
  var id: String { repo }
}

#Preview {
  HomeView()
    .environment(AppEnvironment.preview())
}
