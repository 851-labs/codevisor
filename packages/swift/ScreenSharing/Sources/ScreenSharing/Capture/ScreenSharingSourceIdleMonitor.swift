import Foundation

/// Host capture activity, shared by the capture queue (submissions),
/// VideoToolbox's output queue (encoded output) and the main actor
/// (evaluation). Trailing packet loss before an idle desktop is invisible to
/// RTP sequence feedback, so the host announces idle once with the identity
/// of its newest encoded content. Content that was submitted but never
/// encoded (admission, a WebRTC bandwidth pause, or an adaptation drop) is
/// re-offered: four times at the idle threshold, then at a slow bounded
/// rate until it is encoded, a newer capture arrives or the peer closes.
/// Older content is never announced as current. There is no periodic
/// re-encode: a re-offer costs an encode only when WebRTC accepts it.
package final class ScreenSharingSourceIdleMonitor: @unchecked Sendable {
  package enum Evaluation: Equatable, Sendable {
    case inactive
    case wait(untilNs: Int64)
    case resubmit
    case idle(latestEncodedNs: Int64)
  }

  /// Product default, promoted after the brief-loss measurements: 100 ms of
  /// capture silence announces idle. The former 500 ms remains an explicit
  /// diagnostic override.
  package static let defaultThresholdNs: Int64 = 100_000_000
  package static let legacyThresholdNs: Int64 = 500_000_000
  package static let maximumQuickResubmissions = 4
  package static let slowResubmissionIntervalNs: Int64 = 2_000_000_000
  package let thresholdNs: Int64
  private let slowIntervalNs: Int64
  private let lock = NSLock()
  private var lastSubmittedNs: Int64?
  private var lastSubmissionAtNs: Int64?
  private var lastEncodedNs: Int64?
  private var armed = false
  private var resubmissions = 0
  private var stopped = false

  package init(
    thresholdNs: Int64 = ScreenSharingSourceIdleMonitor.defaultThresholdNs,
    slowIntervalNs: Int64 = ScreenSharingSourceIdleMonitor.slowResubmissionIntervalNs
  ) {
    precondition(thresholdNs > 0 && slowIntervalNs > 0)
    self.thresholdNs = thresholdNs
    // The slow phase never re-offers faster than the quick phase.
    self.slowIntervalNs = max(slowIntervalNs, thresholdNs)
  }

  package var slowResubmissionIntervalNs: Int64 { slowIntervalNs }

  /// Re-offers since the latest capture; at least the quick maximum means the
  /// host is in its slow recovery phase.
  package var resubmissionCount: Int { lock.withLock { resubmissions } }

  /// Returns true only on the idle-to-active transition, which schedules one
  /// evaluation loop. Later submissions during activity cost a lock only.
  package func recordSubmission(timestampNs: Int64, nowNs: Int64) -> Bool {
    lock.withLock {
      guard !stopped else { return false }
      lastSubmittedNs = timestampNs
      lastSubmissionAtNs = nowNs
      resubmissions = 0
      guard !armed else { return false }
      armed = true
      return true
    }
  }

  /// Output delivered to WebRTC; discarded or failed output is never recorded.
  package func recordEncoded(timestampNs: Int64) {
    lock.withLock {
      if let lastEncodedNs, timestampNs <= lastEncodedNs { return }
      lastEncodedNs = timestampNs
    }
  }

  package var latestEncodedNs: Int64? { lock.withLock { lastEncodedNs } }
  package var latestSubmittedNs: Int64? { lock.withLock { lastSubmittedNs } }

  /// Evaluations performed (each is one wake of the notifier loop).
  package var evaluationCount: Int { lock.withLock { evaluations } }
  private var evaluations = 0

  package func evaluate(nowNs: Int64) -> Evaluation {
    lock.withLock {
      evaluations += 1
      guard armed, !stopped, let submittedAt = lastSubmissionAtNs, let submitted = lastSubmittedNs else {
        armed = false
        return .inactive
      }
      let interval = resubmissions < Self.maximumQuickResubmissions ? thresholdNs : slowIntervalNs
      if nowNs < submittedAt + interval { return .wait(untilNs: submittedAt + interval) }
      if let encoded = lastEncodedNs, encoded >= submitted {
        armed = false
        return .idle(latestEncodedNs: encoded)
      }
      resubmissions += 1
      lastSubmissionAtNs = nowNs
      return .resubmit
    }
  }

  package func stop() {
    lock.withLock {
      stopped = true
      armed = false
    }
  }
}

/// Runs only while capture is active: one wake per threshold and none while
/// idle. The capture queue activates it once per activity period. A notice
/// that cannot be sent yet is retained (newest wins) until the channel opens.
@MainActor
package final class ScreenSharingSourceIdleNotifier {
  private let monitor: ScreenSharingSourceIdleMonitor
  private let evaluated: () -> Void
  private let resubmit: () -> Void
  private let notify: (Int64) -> Bool
  private let nowNs: @Sendable () -> Int64
  private let sleep: @Sendable (Duration) async throws -> Void
  private var task: Task<Void, Never>?
  private var pendingNotice: Int64?
  private var closed = false

  package init(
    monitor: ScreenSharingSourceIdleMonitor, evaluated: @escaping () -> Void = {},
    resubmit: @escaping () -> Void, notify: @escaping (Int64) -> Bool,
    nowNs: @escaping @Sendable () -> Int64 = { ScreenSharingMetrics.nowNs },
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.monitor = monitor; self.evaluated = evaluated; self.resubmit = resubmit; self.notify = notify
    self.nowNs = nowNs; self.sleep = sleep
  }

  package var hasPendingNotice: Bool { pendingNotice != nil }

  package func activate() {
    guard !closed, task == nil else { return }
    task = Task { @MainActor [weak self] in await self?.run() }
  }

  /// Retry a retained notice, e.g. when the channel becomes available.
  package func flush() {
    guard !closed, let pendingNotice, notify(pendingNotice) else { return }
    self.pendingNotice = nil
  }

  private func run() async {
    defer { task = nil }
    while !Task.isCancelled, !closed {
      evaluated()
      switch monitor.evaluate(nowNs: nowNs()) {
      case .inactive:
        return
      case .wait(let untilNs):
        do { try await sleep(.nanoseconds(max(0, untilNs - nowNs()))) } catch { return }
      case .resubmit:
        resubmit()
      case .idle(let latestEncodedNs):
        pendingNotice = latestEncodedNs
        flush()
      }
    }
  }

  @discardableResult
  package func close() -> Task<Void, Never>? {
    closed = true
    pendingNotice = nil
    let pending = task
    task = nil
    pending?.cancel()
    return pending
  }
}

/// Handles of a peer's cancelled owned tasks, retained until they complete so
/// that every waiter — concurrent or repeated — joins the same completions.
@MainActor
package final class ScreenSharingOwnedWork {
  package init() {}
  private var handles: [Task<Void, Never>]?

  /// Nil until `close(with:)`; then the number of retained handles.
  package var count: Int? { handles?.count }

  package func close(with tasks: [Task<Void, Never>]) {
    guard handles == nil else { return }
    handles = tasks
  }

  /// Awaits every retained handle. Returns the number awaited, or nil when the
  /// work was never closed (the call then returns immediately).
  package func join() async -> Int? {
    guard let handles else { return nil }
    for task in handles { await task.value }
    return handles.count
  }
}

/// Viewer record of the newest decoded content identity and the host's
/// announced target. The target survives recovery: a delayed older keyframe
/// can complete the keyframe request without delivering the announced content.
package final class ScreenSharingDeliveryAudit: @unchecked Sendable {
  package init() {}
  private let lock = NSLock()
  private var latestDecodedNs: Int64?
  private var targetNs: Int64?
  private var recovering = false
  private var targetMetAtNs: Int64?
  /// Bounded recent decode times so a target that arrived before its notice
  /// still has a first-decode time (diagnostic only; one second at 60 fps).
  private var recentDecodes: [(identity: Int64, atNs: Int64)] = []
  package static let recentDecodeCapacity = 64

  package var latestDecodedTimestampNs: Int64? { lock.withLock { latestDecodedNs } }
  package var pendingTargetNs: Int64? { lock.withLock { targetNs } }
  /// Viewer clock at which the decoder first delivered the announced target
  /// (or newer content), whether before the notice, during grace or after recovery.
  package var targetMetAtTimestampNs: Int64? { lock.withLock { targetMetAtNs } }

  package func decoded(sourceTimestampNs: Int64, nowNs: Int64 = ScreenSharingMetrics.nowNs) {
    lock.withLock {
      if let latestDecodedNs, sourceTimestampNs <= latestDecodedNs { return }
      latestDecodedNs = sourceTimestampNs
      if recentDecodes.count == Self.recentDecodeCapacity { recentDecodes.removeFirst() }
      recentDecodes.append((sourceTimestampNs, nowNs))
      if let targetNs, sourceTimestampNs >= targetNs, targetMetAtNs == nil { targetMetAtNs = nowNs }
    }
  }

  /// True when the announced content (or newer) has already been decoded.
  package func noticed(latestTimestampNs: Int64) -> Bool {
    lock.withLock {
      recovering = false
      targetMetAtNs = nil
      if let latestDecodedNs, latestDecodedNs >= latestTimestampNs {
        targetNs = nil
        targetMetAtNs = recentDecodes.first { $0.identity >= latestTimestampNs }?.atNs
        return true
      }
      targetNs = latestTimestampNs
      return false
    }
  }

  /// True when the target is still unmet after the grace period; recovery
  /// then starts and the target remains until it is met or abandoned.
  package func verify() -> Bool {
    lock.withLock {
      guard let targetNs, !recovering else { return false }
      if let latestDecodedNs, latestDecodedNs >= targetNs {
        self.targetNs = nil
        return false
      }
      recovering = true
      return true
    }
  }

  /// After a keyframe completed recovery: nil when nothing was awaited, false
  /// when the target is now met (and cleared), true when it is still missing.
  package func recoveryFinished() -> Bool? {
    lock.withLock {
      guard let targetNs, recovering else { return nil }
      if let latestDecodedNs, latestDecodedNs >= targetNs {
        self.targetNs = nil
        recovering = false
        return false
      }
      return true
    }
  }

  /// Before a retry: true while the target is still missing; a target met
  /// meanwhile (for example by a delta frame) is cleared instead.
  package func targetMissing() -> Bool {
    lock.withLock {
      guard let targetNs else { return false }
      if let latestDecodedNs, latestDecodedNs >= targetNs {
        self.targetNs = nil
        recovering = false
        return false
      }
      return true
    }
  }
}

/// Waits one grace period for frames still in the jitter buffer, then asks
/// for a keyframe only if the announced content never arrived. Optionally
/// (diagnostic experiment; the product default allows no extension) the wait
/// extends by further grace windows while strictly newer content keeps
/// arriving, up to a fixed cap, and recovery is requested once progress
/// stalls; duplicated or older frames never extend it. When recovery
/// completes without that content (a delayed older keyframe), it asks again
/// after an exponentially growing, capped delay, until the content arrives
/// or the peer closes; stale content is never silently accepted. A newer
/// notice replaces pending work; no timer runs otherwise.
@MainActor
package final class ScreenSharingDeliveryVerifier {
  package enum Outcome: Equatable, Sendable {
    case verified
    case verifiedAfterGrace
    case graceExtended
    case refresh
    case recovered
    case retry
    /// A scheduled retry ran and found the target still missing; a refresh follows.
    case retryExecuted
  }

  /// Product defaults, promoted after the brief-loss measurements: a 100 ms
  /// grace extended up to four more windows while newer content keeps
  /// arriving (at most 500 ms after the notice). The former fixed 500 ms grace
  /// with no extension remains an explicit diagnostic override.
  package static let defaultGrace: Duration = .milliseconds(100)
  package static let defaultGraceExtensions = 4
  package static let legacyGrace: Duration = .milliseconds(500)
  package static let legacyGraceExtensions = 0
  package static let maximumGraceExtensions = 10
  nonisolated static let initialRetryDelayMs: Int64 = 100
  nonisolated static let maximumRetryDelayMs: Int64 = 5000
  private let audit: ScreenSharingDeliveryAudit
  private let grace: Duration
  private let graceExtensions: Int
  private let refresh: () -> Void
  private let report: (Outcome) -> Void
  private let sleep: @Sendable (Duration) async throws -> Void
  private var task: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  /// The grace window in progress, if any. It completes right after reporting
  /// its outcome, so awaiting it observes the verdict.
  package var pendingGrace: Task<Void, Never>? { task }
  private var revision: UInt64 = 0
  private var retries = 0
  private var closed = false

  /// Delay before retry number `retry` (1-based): 100 ms doubling to 5 s.
  nonisolated static func retryDelay(_ retry: Int) -> Duration {
    .milliseconds(min(initialRetryDelayMs << min(max(retry - 1, 0), 10), maximumRetryDelayMs))
  }

  package init(
    audit: ScreenSharingDeliveryAudit, grace: Duration = ScreenSharingDeliveryVerifier.defaultGrace,
    graceExtensions: Int = ScreenSharingDeliveryVerifier.defaultGraceExtensions,
    refresh: @escaping () -> Void, report: @escaping (Outcome) -> Void,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.audit = audit; self.grace = grace; self.refresh = refresh; self.report = report
    self.graceExtensions = min(max(graceExtensions, 0), Self.maximumGraceExtensions)
    self.sleep = sleep
  }

  package func noticed(latestTimestampNs: Int64) {
    guard !closed else { return }
    task?.cancel()
    task = nil
    retryTask?.cancel()
    retryTask = nil
    retries = 0
    if audit.noticed(latestTimestampNs: latestTimestampNs) {
      report(.verified)
      return
    }
    let sleep = sleep
    let grace = grace
    let extensions = graceExtensions
    let target = latestTimestampNs
    var mark = audit.latestDecodedTimestampNs
    task = Task { @MainActor [weak self] in
      var extended = 0
      while true {
        do { try await sleep(grace) } catch { return }
        guard let self, !Task.isCancelled, !self.closed else { return }
        let latest = self.audit.latestDecodedTimestampNs
        // Strictly newer content still short of the target is progress; the
        // audit ignores duplicates and older frames, so `latest` only advances.
        guard extended < extensions, let latest, latest < target, latest != mark else { break }
        mark = latest
        extended += 1
        self.report(.graceExtended)
      }
      guard let self, !Task.isCancelled, !self.closed else { return }
      self.task = nil
      if self.audit.verify() {
        self.report(.refresh)
        self.refresh()
      } else {
        self.report(.verifiedAfterGrace)
      }
    }
  }

  /// Keyframe recovery state from the decoder signal, in revision order.
  package func recoveryChanged(_ event: ScreenSharingRefreshSignal.Event) {
    guard !closed, event.revision > revision else { return }
    revision = event.revision
    guard !event.needed, let missing = audit.recoveryFinished() else { return }
    guard missing else {
      retries = 0
      report(.recovered)
      return
    }
    retries += 1
    report(.retry)
    let sleep = sleep
    let delay = Self.retryDelay(retries)
    retryTask?.cancel()
    retryTask = Task { @MainActor [weak self] in
      do { try await sleep(delay) } catch { return }
      guard let self, !Task.isCancelled, !self.closed else { return }
      self.retryTask = nil
      if self.audit.targetMissing() {
        self.report(.retryExecuted)
        self.refresh()
      } else {
        self.report(.recovered)
      }
    }
  }

  @discardableResult
  package func close() -> Task<Void, Never>? {
    closed = true
    let pending = [task, retryTask].compactMap { $0 }
    task = nil
    retryTask = nil
    for task in pending { task.cancel() }
    guard !pending.isEmpty else { return nil }
    return Task { for task in pending { await task.value } }
  }
}
