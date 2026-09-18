import Foundation

/// Pure decision types for the diagnostic owned-window capture mode. They are
/// platform-neutral so the boundaries are testable without ScreenCaptureKit.

/// Exact selection of the process's own window from current-process shareable
/// content: the window ID must match and the owning process must be this one.
/// Anything else fails closed; there is no display or broader-window fallback.
public enum ScreenSharingOwnedWindowSelection {
  public struct Candidate: Equatable, Sendable {
    public let windowID: UInt32
    public let owningProcessID: Int32?
    public init(windowID: UInt32, owningProcessID: Int32?) {
      self.windowID = windowID; self.owningProcessID = owningProcessID
    }
  }

  public enum Failure: Error, Equatable {
    case windowNotListed
    case owningProcessNotReported
    case owningProcessMismatch(reported: Int32)
    case ambiguous(count: Int)
  }

  public static func select(
    windowID: UInt32, processID: Int32, from candidates: [Candidate]
  ) -> Result<Candidate, Failure> {
    let matches = candidates.filter { $0.windowID == windowID }
    guard !matches.isEmpty else { return .failure(.windowNotListed) }
    guard matches.count == 1, let match = matches.first else { return .failure(.ambiguous(count: matches.count)) }
    guard let owner = match.owningProcessID else { return .failure(.owningProcessNotReported) }
    guard owner == processID else { return .failure(.owningProcessMismatch(reported: owner)) }
    return .success(match)
  }
}

/// Bounded accounting of ScreenCaptureKit sample callbacks by frame status.
/// Only a complete sample with an image buffer is delivered; every other
/// callback is counted under a fixed name and never treated as a pool drop.
public enum ScreenSharingCaptureCallbackAccounting {
  public enum Status: Int, CaseIterable, Sendable {
    case complete = 0, idle = 1, blank = 2, suspended = 3, started = 4, stopped = 5

    public var counterName: String {
      switch self {
      case .complete: "captureCallbacksComplete"
      case .idle: "captureCallbacksIdle"
      case .blank: "captureCallbacksBlank"
      case .suspended: "captureCallbacksSuspended"
      case .started: "captureCallbacksStarted"
      case .stopped: "captureCallbacksStopped"
      }
    }
  }

  public static let otherStatusCounter = "captureCallbacksOtherStatus"
  public static let invalidSampleCounter = "captureSamplesInvalid"
  public static let missingStatusCounter = "captureSamplesWithoutStatus"
  public static let missingImageCounter = "captureSamplesWithoutImage"
  public static let latestStatusLabel = "captureLatestStatus"

  /// Total number of sample callbacks from the counters: every status bucket
  /// plus the unknown-status, invalid-sample and missing-status buckets — which
  /// are mutually exclusive per callback. `captureSamplesWithoutImage` is NOT
  /// added: it is a sub-count of complete callbacks (a complete sample without
  /// an image increments both) and would count such a callback twice.
  public static func callbackTotal(counters: [String: Int]) -> Int {
    let buckets = Status.allCases.map(\.counterName) + [otherStatusCounter, invalidSampleCounter, missingStatusCounter]
    return buckets.reduce(0) { $0 + counters[$1, default: 0] }
  }

  /// Records one callback and returns whether its frame may be delivered.
  @discardableResult
  public static func record(
    valid: Bool, rawStatus: Int?, hasImage: Bool, metrics: ScreenSharingMetrics
  ) -> Bool {
    guard valid else { metrics.increment(invalidSampleCounter); return false }
    guard let rawStatus else { metrics.increment(missingStatusCounter); return false }
    guard let status = Status(rawValue: rawStatus) else {
      metrics.increment(otherStatusCounter)
      metrics.label(latestStatusLabel, "other(\(rawStatus))")
      return false
    }
    metrics.increment(status.counterName)
    metrics.label(latestStatusLabel, String(describing: status))
    guard status == .complete else { return false }
    guard hasImage else { metrics.increment(missingImageCounter); return false }
    return true
  }
}

/// Finite lifecycle of the diagnostic's one owned workload window and its
/// capture stream, with the boundaries the report must record. Transitions
/// are explicit; an out-of-order request is refused rather than reordered.
public struct ScreenSharingOwnedWorkloadLifecycle: Sendable {
  public enum State: String, Sendable {
    case created, shown, ready, capturing, workloadPaused, captureStopped, closed
    /// Closed during cleanup without a completed capture stop (setup failed or
    /// was cancelled after the window was shown, or the stop did not complete).
    case abandoned
  }

  public enum Transition: String, Sendable {
    case show, ready, startCapture, pauseWorkload, stopCapture, close, abandon
  }

  public enum CleanupOutcome: Equatable, Sendable {
    case neverShown
    case closedAfterCaptureStop
    case abandoned(from: State)
    case alreadyFinished(State)
  }

  public struct Refusal: Error, Equatable {
    public let transition: Transition
    public let state: State
  }

  public private(set) var state: State = .created
  public private(set) var timestampsNs: [Transition: Int64] = [:]

  public init() {}

  private static let allowed: [Transition: Set<State>] = [
    .show: [.created],
    .ready: [.shown],
    .startCapture: [.ready],
    .pauseWorkload: [.capturing],
    // Capture stops from the animating or the paused state; the window may
    // only close after its stream has stopped so no callback outlives it.
    .stopCapture: [.capturing, .workloadPaused],
    .close: [.captureStopped],
    // Cleanup of a shown window whose capture never started, never stopped
    // completely, or failed: the window still closes, without claiming a stop.
    .abandon: [.shown, .ready, .capturing, .workloadPaused],
  ]

  private static let next: [Transition: State] = [
    .show: .shown, .ready: .ready, .startCapture: .capturing, .pauseWorkload: .workloadPaused,
    .stopCapture: .captureStopped, .close: .closed, .abandon: .abandoned,
  ]

  public private(set) var abandonedFrom: State?

  public mutating func apply(_ transition: Transition, atNs timestamp: Int64) throws {
    guard Self.allowed[transition, default: []].contains(state) else {
      throw Refusal(transition: transition, state: state)
    }
    if transition == .abandon { abandonedFrom = state }
    state = Self.next[transition]!
    timestampsNs[transition] = timestamp
  }

  /// The one cleanup boundary the probe uses on every exit path. A capture
  /// stop is credited only when the capture itself recorded its completion;
  /// the window closes in order only from `captureStopped`, otherwise it is
  /// abandoned from wherever setup or the run got to. A never-shown window
  /// needs nothing.
  public mutating func cleanUp(captureStopCompleted: Bool, atNs timestamp: Int64) -> CleanupOutcome {
    switch state {
    case .created: return .neverShown
    case .closed, .abandoned: return .alreadyFinished(state)
    case .capturing, .workloadPaused:
      if captureStopCompleted { try? apply(.stopCapture, atNs: timestamp) }
    case .shown, .ready, .captureStopped: break
    }
    if state == .captureStopped {
      try? apply(.close, atNs: timestamp)
      return .closedAfterCaptureStop
    }
    let from = state
    try? apply(.abandon, atNs: timestamp)
    return .abandoned(from: from)
  }

  /// True when the window went through every boundary in order and the
  /// capture stopped before the window closed.
  public var completedInOrder: Bool {
    guard state == .closed, let stop = timestampsNs[.stopCapture], let close = timestampsNs[.close] else {
      return false
    }
    return stop <= close
  }
}

/// Time-driven frame code of the diagnostic workload that can be frozen at a
/// pause boundary. Draws record the code they rendered; `freezeAtLastDrawn`
/// holds exactly that code — never a newly time-derived one — so a pause that
/// lands between frames freezes what was actually drawn last, and every later
/// query (including incidental redraws requested by the window server) returns
/// it. Freezing is distinct from stopping a capture stream.
public struct ScreenSharingWorkloadSequence: Sendable {
  public let framesPerSecond: Int
  public let startedAtSeconds: Double
  public private(set) var lastDrawnCode: Int?
  public private(set) var lastDrawnAtSeconds: Double?
  public private(set) var frozenCode: Int?
  public private(set) var frozenAtSeconds: Double?

  public init(framesPerSecond: Int, startedAtSeconds: Double) {
    self.framesPerSecond = framesPerSecond
    self.startedAtSeconds = startedAtSeconds
  }

  public var isFrozen: Bool { frozenCode != nil }

  /// The code a draw starting at `now` renders; recorded as the last drawn.
  public mutating func drawn(atSeconds now: Double) -> Int {
    let code = frozenCode ?? Int(max(0, now - startedAtSeconds) * Double(framesPerSecond))
    lastDrawnCode = code
    lastDrawnAtSeconds = now
    return code
  }

  /// Freezes at the last DRAWN code (0 if nothing was drawn yet). Idempotent:
  /// the first boundary wins.
  public mutating func freezeAtLastDrawn(atSeconds now: Double) {
    guard frozenCode == nil else { return }
    frozenCode = lastDrawnCode ?? 0
    frozenAtSeconds = now
  }
}
