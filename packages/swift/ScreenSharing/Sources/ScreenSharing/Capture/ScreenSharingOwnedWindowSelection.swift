import Foundation

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

  public static func callbackTotal(counters: [String: Int]) -> Int {
    let buckets = Status.allCases.map(\.counterName) + [otherStatusCounter, invalidSampleCounter, missingStatusCounter]
    return buckets.reduce(0) { $0 + counters[$1, default: 0] }
  }

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

public struct ScreenSharingOwnedWorkloadLifecycle: Sendable {
  public enum State: String, Sendable {
    case created, shown, ready, capturing, workloadPaused, captureStopped, closed
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
    .stopCapture: [.capturing, .workloadPaused],
    .close: [.captureStopped],
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

  public var completedInOrder: Bool {
    guard state == .closed, let stop = timestampsNs[.stopCapture], let close = timestampsNs[.close] else {
      return false
    }
    return stop <= close
  }
}

public struct ScreenSharingWorkloadSequence: Sendable {
  public let framesPerSecond: Int
  public let startedAtSeconds: Double
  public private(set) var lastDrawnCode: Int?
  public private(set) var frozenCode: Int?

  public init(framesPerSecond: Int, startedAtSeconds: Double) {
    self.framesPerSecond = framesPerSecond
    self.startedAtSeconds = startedAtSeconds
  }

  public var isFrozen: Bool { frozenCode != nil }

  public mutating func drawn(atSeconds now: Double) -> Int {
    let code = frozenCode ?? Int(max(0, now - startedAtSeconds) * Double(framesPerSecond))
    lastDrawnCode = code
    return code
  }

  public mutating func freezeAtLastDrawn() {
    guard frozenCode == nil else { return }
    frozenCode = lastDrawnCode ?? 0
  }
}
