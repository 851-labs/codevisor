import Foundation
import Observation
import Sentry

public enum DiagnosticIssueName: String, Sendable, CaseIterable {
  case corruptPersistedData = "corrupt_persisted_data"
  case dataDirectoryUnavailable = "data_directory_unavailable"
  case persistenceWriteFailed = "persistence_write_failed"
  case terminalOpenFailed = "terminal_open_failed"
  case appRelaunchFailed = "app_relaunch_failed"

  fileprivate var component: String {
    switch self {
    case .corruptPersistedData, .dataDirectoryUnavailable, .persistenceWriteFailed:
      "persistence"
    case .terminalOpenFailed:
      "terminal"
    case .appRelaunchFailed:
      "updates"
    }
  }
}

@MainActor
@Observable
public final class DiagnosticsClient {
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

  public func capture(_ issue: DiagnosticIssueName) {
    guard consentGate.isEnabled, sdkIsSetUp else { return }
    SentrySDK.capture(message: issue.rawValue) { scope in
      scope.setTag(value: issue.rawValue, key: "diagnostic_issue")
      scope.setTag(value: issue.component, key: "component")
      scope.setFingerprint([issue.rawValue, "{{ default }}"])
    }
  }

  func noteSyncEvent(machineIsLocal: Bool, kind: String) {
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

  var isEnabled: Bool {
    lock.withLock { enabled }
  }

  func setEnabled(_ value: Bool) {
    lock.withLock { enabled = value }
  }
}

enum DiagnosticsPrivacyFilter {
  private static let allowedMessages = Set(DiagnosticIssueName.allCases.map(\.rawValue))
  private static let allowedTags = Set([
    "component", "diagnostic_issue", "machine_kind", "sync_event_kind",
  ])

  static func sanitize(_ event: Event) -> Event {
    event.user = nil
    event.request = nil
    event.serverName = nil
    event.logger = nil
    event.transaction = nil
    event.extra = nil
    event.modules = nil
    event.breadcrumbs = nil
    event.error = nil

    event.tags = event.tags?.filter { allowedTags.contains($0.key) }
    event.context = sanitizedContext(event.context)

    if let message = event.message {
      if allowedMessages.contains(message.formatted) {
        message.message = nil
        message.params = nil
      } else {
        event.message = nil
      }
    }

    for exception in event.exceptions ?? [] {
      exception.value = nil
      sanitize(exception.stacktrace)
    }
    for thread in event.threads ?? [] {
      thread.name = nil
      sanitize(thread.stacktrace)
    }
    sanitize(event.stacktrace)
    for image in event.debugMeta ?? [] {
      image.codeFile = lastPathComponent(image.codeFile)
    }
    return event
  }

  private static func sanitizedContext(
    _ context: [String: [String: Any]]?
  ) -> [String: [String: Any]]? {
    guard let context else { return nil }
    var result: [String: [String: Any]] = [:]
    copy(["app_identifier", "app_version", "app_build"], from: context["app"], to: &result, key: "app")
    copy(["name", "version"], from: context["os"], to: &result, key: "os")
    copy(["arch"], from: context["device"], to: &result, key: "device")
    return result.isEmpty ? nil : result
  }

  private static func copy(
    _ keys: [String],
    from source: [String: Any]?,
    to destination: inout [String: [String: Any]],
    key: String
  ) {
    guard let source else { return }
    let values = source.filter { keys.contains($0.key) }
    if !values.isEmpty {
      destination[key] = values
    }
  }

  private static func sanitize(_ stacktrace: SentryStacktrace?) {
    for frame in stacktrace?.frames ?? [] {
      frame.fileName = lastPathComponent(frame.fileName)
      frame.package = lastPathComponent(frame.package)
      frame.contextLine = nil
      frame.preContext = nil
      frame.postContext = nil
      frame.vars = nil
    }
  }

  private static func lastPathComponent(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return value }
    return (value as NSString).lastPathComponent
  }
}
