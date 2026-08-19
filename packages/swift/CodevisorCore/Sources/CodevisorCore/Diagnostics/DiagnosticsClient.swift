import Foundation
import Observation
import Sentry

/// The complete allowlist for handled errors sent to Sentry. Callers cannot
/// pass arbitrary strings, errors, URLs, or payloads into remote diagnostics.
public enum DiagnosticIssueName: String, Sendable, CaseIterable {
    case corruptPersistedData = "corrupt_persisted_data"
    case dataDirectoryUnavailable = "data_directory_unavailable"
    case persistenceWriteFailed = "persistence_write_failed"
    case projectSyncFailed = "project_sync_failed"
    case bulkSyncFailed = "bulk_sync_failed"
    case serverDeleteFailed = "server_delete_failed"
    case terminalOpenFailed = "terminal_open_failed"
    case appRelaunchFailed = "app_relaunch_failed"

    fileprivate var component: String {
        switch self {
        case .corruptPersistedData, .dataDirectoryUnavailable, .persistenceWriteFailed:
            "persistence"
        case .projectSyncFailed, .bulkSyncFailed, .serverDeleteFailed:
            "sync"
        case .terminalOpenFailed:
            "terminal"
        case .appRelaunchFailed:
            "updates"
        }
    }
}

/// Consent-gated native crash reporting and allowlisted handled-error capture.
///
/// Release builds initialize Sentry only after the persisted preference is
/// enabled. Debug builds additionally require `CODEVISOR_ENABLE_DIAGNOSTICS=1`,
/// so ordinary development and tests never contact Sentry.
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

    /// Set after startup when Sentry confirms that the preceding opted-in run
    /// crashed. The app uses this to show a transparent, dismissible notice.
    public private(set) var crashedLastRun = false

    private init() {}

    /// Reads the public ingestion DSN embedded by the app target. An opted-out
    /// launch does not initialize Sentry or create its cache directory.
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

    /// Applies the app preference immediately. Revocation closes every Sentry
    /// integration and removes locally queued diagnostic state.
    public func setEnabled(_ enabled: Bool) {
        consentGate.setEnabled(enabled)
        guard dsn != nil else { return }

        if enabled {
            startIfNeeded()
        } else {
            stopAndPurge()
        }
    }

    /// Sends a fixed issue name and a capture-site stack trace. User-facing
    /// titles, underlying Error values, paths, and log messages are excluded.
    public func capture(_ issue: DiagnosticIssueName) {
        guard consentGate.isEnabled, sdkIsSetUp else { return }
        SentrySDK.capture(message: issue.rawValue) { scope in
            scope.setTag(value: issue.rawValue, key: "diagnostic_issue")
            scope.setTag(value: issue.component, key: "component")
            scope.setFingerprint([issue.rawValue, "{{ default }}"])
        }
    }

    /// Keeps only coarse, allowlisted sync context on the crash scope. Event
    /// payloads, machine ids, hostnames, and breadcrumbs remain excluded.
    func noteSyncEvent(machineIsLocal: Bool, kind: String) {
        guard consentGate.isEnabled, sdkIsSetUp, Self.allowedSyncEventKinds.contains(kind)
        else { return }
        SentrySDK.configureScope { scope in
            scope.setTag(value: machineIsLocal ? "local" : "remote", key: "machine_kind")
            scope.setTag(value: kind, key: "sync_event_kind")
        }
    }

    public func dismissCrashNotice() {
        crashedLastRun = false
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

        // Crash stacks and explicit handled issues only. These defaults are
        // repeated deliberately so an SDK upgrade cannot quietly broaden the
        // data surface.
        options.enableCrashHandler = true
        #if os(macOS)
            // macOS-only Sentry option; iOS reports uncaught exceptions through
            // the crash handler itself.
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
        options.onLastRunStatusDetermined = { status, _ in
            guard status == .didCrash, gate.isEnabled else { return }
            Task { @MainActor in
                guard DiagnosticsClient.shared.consentGate.isEnabled else { return }
                DiagnosticsClient.shared.crashedLastRun = true
            }
        }

        SentrySDK.start(options: options)
        sdkIsSetUp = true
    }

    private func stopAndPurge() {
        crashedLastRun = false
        if sdkIsSetUp {
            SentrySDK.close()
            sdkIsSetUp = false
        }
        try? FileManager.default.removeItem(at: Self.cacheDirectoryURL)
    }

    private static var cacheDirectoryURL: URL {
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return
            base
            .appendingPathComponent(CodevisorAppVariant.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }
}

/// A lock-backed consent bit because Sentry can invoke filters on background
/// queues while the public client remains main-actor isolated.
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
            // Exception values can contain assertions, paths, server bodies,
            // or other user-controlled text. The fixed type plus stack is
            // sufficient for grouping and diagnosis.
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
