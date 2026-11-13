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
  var startupError: String?
  @ObservationIgnored private var startupInProgress = false
  @ObservationIgnored let serverAgent = MacServerAgentController()

  private init() {
    guard Self.startsFresh else { return }
    showFirstLaunchSetup()
  }

  private static var startsFresh: Bool {
    !AppPreview.isRunning
      && ClientStorageBootstrap.startsFresh(directory: CodevisorAppVariant.applicationSupportURL())
  }

  private static func makeRuntime(
    serverAgent: MacServerAgentController,
    storage: ClientStorage,
    instanceLease: AppInstanceLease?
  ) -> (environment: AppEnvironment, updater: SparkleUpdateController?, isFirstLaunch: Bool) {
    let environment = AppEnvironment.live(storage: storage)
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
    Analytics.sink = AnalyticsClient.shared
    Diagnostics.sink = DiagnosticsClient.shared
    AnalyticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareAnalytics)
    AnalyticsClient.shared.captureAppOpenedOnce()
    DiagnosticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareCrashReports)
    ChatNotificationManager.shared.attach(to: environment)
    SidebarQuietChildren.muteAnnouncements(on: environment)
    RetiredChildDisclosure.clear()
    return (environment, sparkleUpdater, isFirstLaunch)
  }

  func retry() {
    startupError = nil
    firstLaunchSetup?.retryLocalData()
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
      sparkleUpdater = runtime.updater
      AppDelegate.current?.settings = runtime.environment.settings
      AppDelegate.current?.appUpdate = runtime.environment.appUpdate
      startupError = nil
      let folders = followFolderQuestions(runtime.environment)
      if runtime.isFirstLaunch, !AppPreview.isRunning {
        startFirstLaunchSetup(runtime.environment, folders: folders)
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
      firstLaunchSetup?.localDataFailed()
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

  private func startFirstLaunchSetup(_ environment: AppEnvironment, folders: FirstRunFolderAccess) {
    ClientPreferences.shared.set(true, forKey: RootSidebarVisibility.collapsedKey)
    ClientPreferences.shared.set(false, forKey: WorkspaceInspectorPresentation.presentedKey)
    let setup = firstLaunchSetup ?? showFirstLaunchSetup()
    Task { await setup.run(LiveFirstLaunchSetupWork(environment: environment, folders: folders)) }
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
