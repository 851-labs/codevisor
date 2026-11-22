import CodevisorCore
import Foundation
import Observation
import Sentry

@MainActor
@Observable
public final class DiagnosticsClient: DiagnosticsSink {
  public static let shared = DiagnosticsClient()

  private static let dsnKey = "CodevisorSentryDSN"
  private static let allowedSyncEventKinds: Set<String> = [
    "project.created", "project.updated", "project.deleted",
    "worktree.created",
    "session.created", "session.updated", "session.deleted",
    "session.attention.updated", "session.archived", "session.unarchived",
    "workspace.updated", "workspace.deleted",
    "workspace.pane.updated", "workspace.pane.deleted",
    "harness.lifecycle.updated",
  ]
  private let consentGate = DiagnosticsConsentGate()
  private var dsn: String?
  private var sdkIsSetUp = false

  private init() {}

  public func configureFromMainBundle(enabled: Bool) {
    guard dsn == nil else {
      setEnabled(enabled)
      return
    }

    #if DEBUG
      guard ProcessInfo.processInfo.environment["CODEVISOR_ENABLE_DIAGNOSTICS"] == "1" else {
        consentGate.setEnabled(false)
        return
      }
    #endif

    guard let value = Bundle.main.object(forInfoDictionaryKey: Self.dsnKey) as? String,
      !value.isEmpty,
      !value.hasPrefix("$("),
      URL(string: value)?.scheme == "https"
    else { return }

    dsn = value
    setEnabled(enabled)
  }

  public func setEnabled(_ enabled: Bool) {
    consentGate.setEnabled(enabled)
    guard dsn != nil else { return }

    if enabled {
      startIfNeeded()
    } else {
      stopAndPurge()
    }
  }

  public func setContext(_ context: TelemetryContext) {
    consentGate.setContextTags(context.tags)
  }

  public func capture(_ error: ReportedError) {
    guard consentGate.isEnabled, sdkIsSetUp else { return }
    SentrySDK.capture(message: error.title) { scope in
      scope.setTag(value: error.issue, key: "diagnostic_issue")
      scope.setTag(value: error.component, key: "component")
      scope.setContext(
        value: DiagnosticsPrivacyFilter.reportedContext(error),
        key: DiagnosticsPrivacyFilter.reportedContextKey
      )
      scope.setFingerprint([error.issue, error.title])
    }
  }

  public func noteSyncEvent(machineIsLocal: Bool, kind: String) {
    guard consentGate.isEnabled, sdkIsSetUp, Self.allowedSyncEventKinds.contains(kind)
    else { return }
    SentrySDK.configureScope { scope in
      scope.setTag(value: machineIsLocal ? "local" : "remote", key: "machine_kind")
      scope.setTag(value: kind, key: "sync_event_kind")
    }
  }

  private func startIfNeeded() {
    guard !sdkIsSetUp, let dsn else { return }

    let gate = consentGate
    let options = Options()
    options.dsn = dsn
    options.environment = CodevisorAppVariant.isDevelopment ? "development" : "production"
    options.dist = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    options.cacheDirectoryPath = Self.cacheDirectoryURL.path
    options.debug = false
    options.sampleRate = 1
    options.shutdownTimeInterval = 0

    options.enableCrashHandler = true
    #if os(macOS)
      options.enableUncaughtNSExceptionReporting = false
    #endif
    options.enableSigtermReporting = false
    options.enableAutoSessionTracking = false
    options.enableWatchdogTerminationTracking = false
    options.enableAppHangTracking = false
    options.enableMetricKit = false
    options.enableAutoPerformanceTracing = false
    options.tracesSampleRate = 0
    options.enablePersistingTracesWhenCrashing = false
    options.enableNetworkTracking = false
    options.enableNetworkBreadcrumbs = false
    options.enableCaptureFailedRequests = false
    options.enableFileIOTracing = false
    options.enableDataSwizzling = false
    options.enableFileManagerSwizzling = false
    options.enableCoreDataTracing = false
    options.enableSwizzling = false
    options.enableAutoBreadcrumbTracking = false
    options.maxBreadcrumbs = 0
    options.enableLogs = false
    options.enableMetrics = false
    options.sendClientReports = false
    options.sendDefaultPii = false
    options.attachAllThreads = false

    options.beforeBreadcrumb = { _ in nil }
    options.beforeSendSpan = { _ in nil }
    options.beforeSendLog = { _ in nil }
    options.beforeSendMetric = { _ in nil }
    options.beforeSend = { event in
      guard gate.isEnabled else { return nil }
      event.tags = (event.tags ?? [:]).merging(gate.contextTags) { _, context in context }
      return DiagnosticsPrivacyFilter.sanitize(event)
    }
    SentrySDK.start(options: options)
    sdkIsSetUp = true
  }

  private func stopAndPurge() {
    if sdkIsSetUp {
      SentrySDK.close()
      sdkIsSetUp = false
    }
    try? FileManager.default.removeItem(at: Self.cacheDirectoryURL)
  }

  private static var cacheDirectoryURL: URL {
    CodevisorAppVariant.cacheURL().appendingPathComponent("Diagnostics", isDirectory: true)
  }
}

private final class DiagnosticsConsentGate: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false
  private var tags: [String: String] = [:]

  var isEnabled: Bool {
    lock.withLock { enabled }
  }

  var contextTags: [String: String] {
    lock.withLock { tags }
  }

  func setEnabled(_ value: Bool) {
    lock.withLock { enabled = value }
  }

  func setContextTags(_ value: [String: String]) {
    lock.withLock { tags = value }
  }
}
