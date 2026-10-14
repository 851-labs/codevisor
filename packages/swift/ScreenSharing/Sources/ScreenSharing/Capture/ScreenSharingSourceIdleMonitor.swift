import Foundation

package final class ScreenSharingSourceIdleMonitor: @unchecked Sendable {
  package enum Evaluation: Equatable, Sendable {
    case inactive
    case wait(untilNs: Int64)
    case resubmit
    case idle(latestEncodedNs: Int64)
  }

  package static let defaultThresholdNs: Int64 = 100_000_000
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
    self.slowIntervalNs = max(slowIntervalNs, thresholdNs)
  }

  package var slowResubmissionIntervalNs: Int64 { slowIntervalNs }

  package var resubmissionCount: Int { lock.withLock { resubmissions } }

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

  package func recordEncoded(timestampNs: Int64) {
    lock.withLock {
      if let lastEncodedNs, timestampNs <= lastEncodedNs { return }
      lastEncodedNs = timestampNs
    }
  }

  package var latestEncodedNs: Int64? { lock.withLock { lastEncodedNs } }
  package var latestSubmittedNs: Int64? { lock.withLock { lastSubmittedNs } }

  package func evaluate(nowNs: Int64) -> Evaluation {
    lock.withLock {
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

@MainActor
package final class ScreenSharingOwnedWork {
  package init() {}
  private var handles: [Task<Void, Never>]?

  package func close(with tasks: [Task<Void, Never>]) {
    guard handles == nil else { return }
    handles = tasks
  }

  package func join() async -> Int? {
    guard let handles else { return nil }
    for task in handles { await task.value }
    return handles.count
  }
}

package final class ScreenSharingDeliveryAudit: @unchecked Sendable {
  package init() {}
  private let lock = NSLock()
  private var latestDecodedNs: Int64?
  private var targetNs: Int64?
  private var recovering = false
  private var targetMetAtNs: Int64?
  private var recentDecodes: [(identity: Int64, atNs: Int64)] = []
  package static let recentDecodeCapacity = 64

  package var latestDecodedTimestampNs: Int64? { lock.withLock { latestDecodedNs } }
  package var pendingTargetNs: Int64? { lock.withLock { targetNs } }
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

@MainActor
package final class ScreenSharingDeliveryVerifier {
  package enum Outcome: Equatable, Sendable {
    case verified
    case verifiedAfterGrace
    case graceExtended
    case refresh
    case recovered
    case retry
    case retryExecuted
  }

  package static let defaultGrace: Duration = .milliseconds(100)
  package static let defaultGraceExtensions = 4
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
  package var pendingGrace: Task<Void, Never>? { task }
  private var revision: UInt64 = 0
  private var retries = 0
  private var closed = false

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
