import Foundation

nonisolated struct StartupHealthWatch: Equatable {
  typealias Instant = LocalServerScheduler.Instant

  static let deadJobProbeThreshold = 3
  static let reportEvery = 8

  let expectedBootId: String?
  let requiresBundledIdentity: Bool
  let deadline: Instant
  let stallTimeout: Duration
  let progressAttemptLimit: Int
  private(set) var lastProgressAt: Instant
  private(set) var attempt = 0
  private(set) var attemptLimit: Int
  private(set) var lastProbeError = "none"
  private(set) var deadJobProbes = 0

  init(
    expectedBootId: String?,
    requiresBundledIdentity: Bool,
    deadline: Instant,
    lastProgressAt: Instant,
    stallTimeout: Duration,
    attemptLimit: Int,
    progressAttemptLimit: Int
  ) {
    self.expectedBootId = expectedBootId
    self.requiresBundledIdentity = requiresBundledIdentity
    self.deadline = deadline
    self.lastProgressAt = lastProgressAt
    self.stallTimeout = stallTimeout
    self.attemptLimit = attemptLimit
    self.progressAttemptLimit = progressAttemptLimit
  }

  var hasAttemptsLeft: Bool {
    attempt < attemptLimit
  }

  var isReportDue: Bool {
    attempt % Self.reportEvery == 0 || attempt == attemptLimit
  }

  mutating func beginAttempt() {
    attempt += 1
  }

  mutating func noteProgress(at now: Instant) {
    lastProgressAt = now
    attemptLimit = max(attemptLimit, progressAttemptLimit)
  }

  func isPastDeadline(at now: Instant) -> Bool {
    now >= deadline
  }

  func hasStalled(at now: Instant) -> Bool {
    now - lastProgressAt >= stallTimeout
  }

  mutating func noteFailedProbe(_ reason: String) {
    lastProbeError = reason
  }

  mutating func noteJobProbe(_ running: Bool?) -> JobProbeNote {
    switch running {
    case true?:
      deadJobProbes = 0
      return JobProbeNote(text: ", launchd job running", givesUp: false)
    case false?:
      deadJobProbes += 1
      return JobProbeNote(
        text: ", launchd job has no process (\(deadJobProbes)/\(Self.deadJobProbeThreshold))",
        givesUp: deadJobProbes >= Self.deadJobProbeThreshold
      )
    case nil:
      return JobProbeNote(text: ", launchd job state unknown", givesUp: false)
    }
  }

  func progressReport(jobNote: String) -> String {
    "waitUntilHealthy: attempt \(attempt)/\(attemptLimit), last probe: \(lastProbeError)\(jobNote)"
  }

  func stalledMessage(waitingOn stage: String?) -> String {
    "Server startup stopped progressing while \(stage?.lowercased() ?? "waiting for a response")."
  }

  func jobExitedMessage(logPath: String) -> String {
    "Codevisor's background server exited before becoming ready (last probe: \(lastProbeError)). See \(logPath)"
  }

  func timeoutMessage(logPath: String) -> String {
    "Timed out waiting for Codevisor server after \(attempt) attempt(s) (last probe: \(lastProbeError)). See \(logPath)"
  }
}

nonisolated struct JobProbeNote: Equatable {
  let text: String
  let givesUp: Bool
}
