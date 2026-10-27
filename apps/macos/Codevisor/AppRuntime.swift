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
  var startupError: String?
  @ObservationIgnored private var startupInProgress = false
  @ObservationIgnored let serverAgent = MacServerAgentController()

  private static func makeRuntime(
    serverAgent: MacServerAgentController,
    storage: ClientStorage,
    instanceLease: AppInstanceLease?
  ) -> (environment: AppEnvironment, updater: SparkleUpdateController?, isFirstLaunch: Bool) {
    let environment = AppEnvironment.live(storage: storage)
    environment.syncClientPreferences(SyncedPreferences.keys)
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
    AnalyticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareAnalytics)
    AnalyticsClient.shared.captureAppOpenedOnce()
    DiagnosticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareCrashReports)
    ChatNotificationManager.shared.attach(to: environment)
    return (environment, sparkleUpdater, isFirstLaunch)
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
      sparkleUpdater = runtime.updater
      AppDelegate.current?.settings = runtime.environment.settings
      AppDelegate.current?.appUpdate = runtime.environment.appUpdate
      startupError = nil
      if runtime.isFirstLaunch, !AppPreview.isRunning {
        startFirstLaunchSetup(runtime.environment)
      }
      if !AppPreview.isRunning {
        Task { @MainActor in
          await runtime.environment.prepareAllMachines()
          TerminalRuntime.prewarm()
        }
      }
    } catch {
      startupError = error.localizedDescription
    }
  }

  private func startFirstLaunchSetup(_ environment: AppEnvironment) {
    ClientPreferences.shared.set(true, forKey: RootView.sidebarCollapsedKey)
    ClientPreferences.shared.set(false, forKey: WorkspaceInspectorPresentation.presentedKey)
    let setup = FirstLaunchSetup(work: LiveFirstLaunchSetupWork(environment: environment))
    firstLaunchSetup = setup
    firstLaunchLanding = FirstLaunchLanding()
    Task { await setup.run() }
  }
}
