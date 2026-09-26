import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import Observation
import SwiftUI

/// The app's runtime: client data, the local server connection, machines and updates. It
/// belongs to the app, not to a window (851-2386): started from a window's `.task`, a Codevisor
/// launched without a window (`open -g`, nothing to restore) never connected to its local server,
/// so this Mac couldn't host Screen Sharing or answer anything else it relays. The app delegate
/// starts it at launch; a window that appears first starts it too.
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
      // Keep the bundled CLI (`codevisor` etc.) linked into
      // ~/.local/bin: DMG drag-installs run no installer script, so
      // launch is the only chance to put the CLI on PATH; install.sh
      // and the Homebrew cask create the same links up front.
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
        // Survives the restart that granting Screen Recording asks
        // for; the dialog's own buttons clear it.
        environment.settings.setPermissionsReviewInProgress(true)
      } else if allGranted,
        environment.settings.permissionsReviewedVersion
          != AppUpdateModel.bundleVersion()
      {
        // Everything already granted and no review open: count this
        // version reviewed so a later revoke does not re-gate it.
        environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
      }
    }
    AnalyticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareAnalytics)
    AnalyticsClient.shared.captureAppOpenedOnce()
    DiagnosticsClient.shared.configureFromMainBundle(enabled: environment.settings.shareCrashReports)
    ChatNotificationManager.shared.configure(settings: environment.settings)
    // Attention pings and banner clearing are decided by the app-wide
    // coordinator (edge-triggered, focused chat suppressed); the manager
    // only presents them.
    environment.attentionCoordinator.notificationDelivery = ChatNotificationManager.shared
    // Deep links that open machine-scoped Settings pages ("Manage
    // Harnesses…") resolve the selected machine through this.
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
        directory: CodevisorAppVariant.applicationSupportURL(),
        credentials: KeychainMachineCredentialStore.shared
      )
      let runtime = Self.makeRuntime(
        serverAgent: serverAgent,
        storage: storage,
        instanceLease: AppDelegate.current?.appInstanceLease
      )
      environment = runtime.environment
      sparkleUpdater = runtime.updater
      // The quit confirmation reads the user's preference and skips
      // itself while Sparkle is installing an update.
      AppDelegate.current?.settings = runtime.environment.settings
      AppDelegate.current?.appUpdate = runtime.environment.appUpdate
      startupError = nil
      if !AppPreview.isRunning {
        // Machine readiness belongs to the app runtime, not a window.
        // Settings can be the only restored scene at launch, so waiting
        // until RootView mounts leaves every normal server request gated.
        Task { @MainActor in
          await runtime.environment.prepareAllMachines()
          // Initialize the terminal runtime up front, in a clean context,
          // so opening the terminal later can't re-enter its dispatch_once.
          TerminalRuntime.prewarm()
        }
      }
    } catch {
      startupError = error.localizedDescription
    }
  }
}
