import CodevisorCore
import CodevisorUI
import ScreenSharingPane
import SwiftUI

@main
struct CodevisorApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @State private var environment: AppEnvironment?
  @State private var startupError: String?
  @State private var startupInProgress = false
  @State private var hasCompletedBootstrap = false
  @State private var recoveryInProgress = false
  @State private var recoveryRequestedAgain = false

  init() {
    _environment = State(initialValue: nil)
    _startupError = State(initialValue: nil)
  }

  var body: some Scene {
    WindowGroup {
      WindowIdentityRoot {
        #if DEBUG
          if AppStoreScreenshotData.isEnabled {
            AppStoreScreenshotRoot()
          } else {
            applicationContent(initialRoute: nil)
          }
        #else
          applicationContent(initialRoute: nil)
        #endif
      }
    }
    .commands { CodevisorCommands() }
    WindowGroup(for: WorkspaceWindowRoute.self) { $route in
      WindowIdentityRoot {
        applicationContent(initialRoute: route?.homeRoute)
      }
    }
  }

  @ViewBuilder
  private func applicationContent(initialRoute: HomeRoute?) -> some View {
    if let environment {
      HomeView(initialRoute: initialRoute)
        .modifier(ThemedRoot())
        .environment(environment)
        .task { await bootstrap(environment: environment) }
        .task(id: ObjectIdentifier(environment)) { BotMascotActivities(environment: environment).read() }
        .task(id: environment.machines.sandboxMachineProfilesLoadKey) {
          await environment.machines.loadSandboxMachineProfiles()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
          environment.attentionCoordinator.setApplicationActive(
            phase == .active
          )
          guard phase == .active, hasCompletedBootstrap else { return }
          Task { await recoverAfterForeground(environment: environment) }
        }
        .onChange(of: environment.networkPath.recoveryToken) { _, _ in
          guard scenePhase == .active, hasCompletedBootstrap else { return }
          Task { await recoverAfterForeground(environment: environment) }
        }
    } else if let startupError {
      ClientDataStartupFailureView(
        message: startupError,
        retry: retryStartup
      )
    } else {
      CodevisorStartupSplashView()
        .task { await startEnvironmentIfNeeded() }
    }
  }

  private static func makeEnvironment(storage: ClientStorage) -> AppEnvironment {
    let store = storage.store
    let launchSnapshot = storage.launchSnapshot
    let composerDrafts = ComposerDraftStore(
      store: store,
      attachmentFiles: ComposerAttachmentFileStore(
        root: URL.applicationSupportDirectory
          .appendingPathComponent("Codevisor", isDirectory: true)
          .appendingPathComponent("ComposerAttachments", isDirectory: true)
      ),
      launchSnapshot: launchSnapshot
    )
    composerDrafts.removeUnreferencedAttachmentFiles()
    let environment = AppEnvironment(
      navigationPersistence: store,
      launchSnapshot: launchSnapshot,
      transcriptCache: .shared,
      configCache: ConfigOptionCache(store: store, launchSnapshot: launchSnapshot),
      composerDefaults: ComposerDefaultsStore(store: store),
      composerDrafts: composerDrafts,
      settings: AppSettingsModel(store: store, launchSnapshot: launchSnapshot),
      machineStore: store,
      cloudCredentialStore: KeychainCloudCredentialStore.shared,
      paneGroups: DefaultPaneGroupRepository(store: store)
    )
    ScreenSharingPaneModel.enableEngineV2(environment: environment)
    environment.startNetworkMonitoring()
    #if DEBUG
      if !HomeSidebarSampleData.isEnabled {
        environment.syncClientPreferences(SidebarPreferenceKey.synced)
        environment.syncFeatureFlags()
      }
    #else
      environment.syncClientPreferences(SidebarPreferenceKey.synced)
      environment.syncFeatureFlags()
    #endif
    return environment
  }

  private func retryStartup() {
    startupError = nil
    Task { await startEnvironmentIfNeeded() }
  }

  @MainActor
  private func startEnvironmentIfNeeded() async {
    guard environment == nil, !startupInProgress else { return }
    startupInProgress = true
    defer { startupInProgress = false }
    do {
      let directory = URL.applicationSupportDirectory
        .appendingPathComponent("Codevisor", isDirectory: true)
      let storage = try await ClientStorageBootstrap.openAsync(directory: directory)
      RetiredChildDisclosure.clear()
      environment = Self.makeEnvironment(storage: storage)
      startupError = nil
    } catch {
      startupError = error.localizedDescription
    }
  }

  private func bootstrap(environment: AppEnvironment) async {
    environment.onSessionStateChanged = { session, revision in
      guard
        let controller = ChatControllerCache.shared.existingController(
          sessionId: session.id, serverId: session.serverId)
      else { return }
      Task { await controller.reconcileServerSummary(session, revision: revision) }
    }
    let machines = environment.machines
    let hasConfiguredRemote = machines.machines.contains {
      !$0.isLocal && !$0.isCloud
    }
    if hasConfiguredRemote {
      await environment.prepareAllMachines()
      await environment.cloud.bootstrap()
      await environment.prepareAllMachines()
    } else {
      await environment.cloud.bootstrap()
      await environment.prepareAllMachines()
    }
    hasCompletedBootstrap = true
    Task {
      await environment.updateCenter.resumePendingSessionIfNeeded()
      await environment.updateCenter.refresh()
      await environment.configSync.synchronizeAll()
    }
  }

  private func recoverAfterForeground(environment: AppEnvironment) async {
    guard !recoveryInProgress else {
      recoveryRequestedAgain = true
      return
    }
    recoveryInProgress = true
    defer { recoveryInProgress = false }
    repeat {
      recoveryRequestedAgain = false
      async let roster: Void = environment.cloud.retryIfUnverified()
      async let hub: Void = environment.cloud.reconnectHub()
      environment.machines.verifyConnections()
      async let chatRecovery: Void = ChatControllerCache.shared.reconcileInFlightControllers()
      TerminalSessionCache.shared.reconnectAll()
      _ = await (roster, hub, chatRecovery)
    } while recoveryRequestedAgain
    Task { await environment.updateCenter.backgroundRefresh() }
  }
}

private struct CodevisorStartupSplashView: View {
  @State private var showsSpinner = false

  private var title: String {
    guard CodevisorAppVariant.isDevelopment,
      CodevisorAppVariant.developmentInstanceID != nil
    else { return "Codevisor" }
    return "Codevisor (\(CodevisorAppVariant.developmentWorktreeName))"
  }

  var body: some View {
    ZStack {
      Color(.systemBackground)
        .ignoresSafeArea()

      VStack(spacing: 18) {
        CodevisorAppIconView(size: 112)

        Text(title)
          .font(.title2.weight(.semibold))

        ZStack {
          if showsSpinner {
            ProgressView()
              .controlSize(.regular)
              .tint(.secondary)
              .transition(.opacity)
          }
        }
        .frame(height: 24)
        .accessibilityHidden(!showsSpinner)
      }
      .task {
        do {
          try await Task.sleep(for: .milliseconds(500))
        } catch {
          return
        }
        withAnimation(.easeInOut(duration: 0.15)) {
          showsSpinner = true
        }
      }
    }
  }
}

private struct ClientDataStartupFailureView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Codevisor Couldn't Open Its Data", systemImage: "externaldrive.badge.exclamationmark")
    } description: {
      Text("The app stopped before loading or syncing so your existing data remains intact.\n\n\(message)")
    } actions: {
      Button("Try Again", action: retry)
        .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }
}
