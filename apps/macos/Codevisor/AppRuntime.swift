import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import Observation
import SwiftUI

@MainActor
@Observable
final class AppRuntime {
  static let shared = AppRuntime()

  private(set) var environment: AppEnvironment?
  private(set) var sparkleUpdater: SparkleUpdateController?
  private(set) var firstLaunchSetup: FirstLaunchSetup?
  private(set) var firstLaunchLanding: FirstLaunchLanding?
  private(set) var firstRunFolders: FirstRunFolderAccess?
  private(set) var firstRunClaudeCodeLogin: FirstRunClaudeCodeLogin?
  @ObservationIgnored private(set) var screenSharing: ScreenSharingConnections?
  var startupError: String?
  @ObservationIgnored private var startupInProgress = false
  @ObservationIgnored let serverAgent = MacServerAgentController()

  private init() {
    guard Self.startsFresh else { return }
    showFirstLaunchSetup()
  }

  private static var startsFresh: Bool {
    guard !AppPreview.isRunning else { return false }
    return DeviceDataDeletion.isPending
      || ClientStorageBootstrap.startsFresh(directory: CodevisorAppVariant.applicationSupportURL())
  }

  private static func makeRuntime(
    serverAgent: MacServerAgentController,
    storage: ClientStorage,
    instanceLease: AppInstanceLease?
  ) -> (environment: AppEnvironment, updater: SparkleUpdateController?, isFirstLaunch: Bool) {
    let environment = AppEnvironment.live(storage: storage)
    environment.onDeleteAllData = { DeviceDataDeletion.relaunchIntoDeletion() }
    environment.syncClientPreferences(SyncedPreferences.keys)
    environment.syncFeatureFlags()
    if !CodevisorAppVariant.isDevelopment && !StandaloneServerPreference.isEnabled {
      environment.localServer?.configureManagedService(serverAgent.managedService)
    }
    let sparkleUpdater: SparkleUpdateController?
    if CodevisorAppVariant.enablesSparkleUpdater, let instanceLease {
      sparkleUpdater = SparkleUpdateController(
        model: environment.appUpdate,
        localServer: environment.localServer,
        serverAgent: serverAgent,
        instanceLease: instanceLease
      )
    } else {
      sparkleUpdater = nil
    }
    if !CodevisorAppVariant.isDevelopment && !AppPreview.isRunning {
      Task.detached(priority: .utility) {
        CommandLineTools.ensureInstalled()
      }
    }
    let isFirstLaunch = environment.settings.claimFirstLaunch()
    if !AppPreview.isRunning {
      startReporting(environment.settings)
    }
    ChatNotificationManager.shared.attach(to: environment)
    SidebarQuietChildren.muteAnnouncements(on: environment)
    RetiredChildDisclosure.clear()
    return (environment, sparkleUpdater, isFirstLaunch)
  }

  private static func startReporting(_ settings: AppSettingsModel) {
    Analytics.sink = AnalyticsClient.shared
    Diagnostics.sink = DiagnosticsClient.shared
    AnalyticsClient.shared.configureFromMainBundle(enabled: settings.shareAnalytics)
    AnalyticsClient.shared.captureAppOpenedOnce()
    DiagnosticsClient.shared.configureFromMainBundle(enabled: settings.shareCrashReports)
  }

  func retry() {
    startupError = nil
    Task { await startIfNeeded() }
  }

  func startIfNeeded() async {
    guard environment == nil, !startupInProgress else { return }
    startupInProgress = true
    defer { startupInProgress = false }
    do {
      let storage = try await ClientStorageBootstrap.openAsync(
        directory: CodevisorAppVariant.applicationSupportURL())
      let runtime = Self.makeRuntime(
        serverAgent: serverAgent,
        storage: storage,
        instanceLease: AppDelegate.current?.appInstanceLease
      )
      environment = runtime.environment
      screenSharing = ScreenSharingConnections(source: .live(runtime.environment))
      sparkleUpdater = runtime.updater
      AppDelegate.current?.settings = runtime.environment.settings
      AppDelegate.current?.appUpdate = runtime.environment.appUpdate
      startupError = nil
      let folders = followFolderQuestions(runtime.environment)
      let claudeCodeLogin = followClaudeCodeLoginQuestion(runtime.environment)
      if runtime.isFirstLaunch, !AppPreview.isRunning {
        startFirstLaunchSetup(runtime.environment, folders: folders, claudeCodeLogin: claudeCodeLogin)
      } else {
        closeFirstLaunchSetup()
      }
      if !AppPreview.isRunning {
        runtime.environment.startNetworkMonitoring()
        Task { @MainActor in
          await runtime.environment.prepareAllMachines()
          TerminalRuntime.prewarm()
        }
      }
    } catch {
      startupError = error.localizedDescription
    }
  }

  private func followFolderQuestions(_ environment: AppEnvironment) -> FirstRunFolderAccess {
    let folders = FirstRunFolderAccess(
      client: environment.machines.client(for: CodevisorMachine.local.id),
      permission: ProtectedFolderPermission.check
    )
    firstRunFolders = folders
    if !AppPreview.isRunning {
      Task { await folders.follow() }
    }
    return folders
  }

  private func followClaudeCodeLoginQuestion(_ environment: AppEnvironment) -> FirstRunClaudeCodeLogin {
    let login = FirstRunClaudeCodeLogin(client: environment.machines.client(for: CodevisorMachine.local.id))
    firstRunClaudeCodeLogin = login
    if !AppPreview.isRunning {
      Task { await login.follow() }
    }
    return login
  }

  private func startFirstLaunchSetup(
    _ environment: AppEnvironment,
    folders: FirstRunFolderAccess,
    claudeCodeLogin: FirstRunClaudeCodeLogin
  ) {
    ClientPreferences.shared.set(true, forKey: RootSidebarVisibility.collapsedKey)
    ClientPreferences.shared.set(false, forKey: WorkspaceInspectorPresentation.presentedKey)
    let setup = firstLaunchSetup ?? showFirstLaunchSetup()
    let work = LiveFirstLaunchSetupWork(environment: environment, folders: folders, claudeCodeLogin: claudeCodeLogin)
    Task { await setup.run(work) }
  }

  @discardableResult
  private func showFirstLaunchSetup() -> FirstLaunchSetup {
    let setup = FirstLaunchSetup()
    firstLaunchSetup = setup
    firstLaunchLanding = FirstLaunchLanding()
    return setup
  }

  private func closeFirstLaunchSetup() {
    firstLaunchSetup = nil
    firstLaunchLanding = nil
  }
}
