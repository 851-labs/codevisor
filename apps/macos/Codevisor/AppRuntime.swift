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
  var startupError: String?
  @ObservationIgnored private var startupInProgress = false
  @ObservationIgnored let serverAgent = MacServerAgentController()

  private static func makeRuntime(
    serverAgent: MacServerAgentController,
    storage: ClientStorage,
    instanceLease: AppInstanceLease?
  ) -> (environment: AppEnvironment, updater: SparkleUpdateController?) {
    let environment = AppEnvironment.live(storage: storage)
    environment.syncClientPreferences(SyncedPreferences.keys)
    if !CodevisorAppVariant.isDevelopment {
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
    if !AppPreview.isRunning {
      let probes = ComputerUsePermissionProbes.live
      let allGranted = probes.isAccessibilityGranted() && probes.isScreenRecordingGranted()
      let needsReview = computerUsePermissionsGateNeeded(
        hasCompletedOnboarding: environment.settings.hasCompletedOnboarding,
        permissionsReviewedVersion: environment.settings.permissionsReviewedVersion,
        setupSkipped: environment.settings.permissionsSetupSkipped,
        reviewInProgress: environment.settings.permissionsReviewInProgress,
        currentVersion: AppUpdateModel.bundleVersion(),
        allGranted: allGranted
      )
      environment.requiresPermissionsReview = needsReview
      if needsReview {
        environment.settings.setPermissionsReviewInProgress(true)
      } else if allGranted,
        environment.settings.permissionsReviewedVersion
          != AppUpdateModel.bundleVersion()
      {
        environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
      }
    }
    AnalyticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareAnalytics)
    AnalyticsClient.shared.captureAppOpenedOnce()
    DiagnosticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareCrashReports)
    ChatNotificationManager.shared.configure(settings: environment.settings)
    environment.attentionCoordinator.notificationDelivery = ChatNotificationManager.shared
    return (environment, sparkleUpdater)
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
}
