import Foundation
import QuartzCore

/// Role-tagged (receiver or sender), opt-in lifecycle for WebRTC's shipped RTC
/// event log (`startRtcEventLogWithFilePath:maxSizeInBytes:` /
/// `stopRtcEventLog`), a diagnostic. Disabled (nil) means nothing is allocated
/// and nothing is scheduled; the product path never creates one. The object
/// decides only WHEN the two synchronous API calls happen (from the probe's
/// existing measurement ticks) and records, immutably once final, the requested
/// window, the actual `CACurrentMediaTime()` nanoseconds read immediately
/// before and after each call ("bracket A"), the start call's Bool, whether a
/// successful start was stopped exactly once, and the close reason. It never
/// inspects the file: an absent end event stays an offline finding (stop
/// returns void) and a `true` start is an accepted output, not a complete file.
/// Packet timestamps are this role's own WebRTC logging point — never a socket
/// or NIC boundary — and the role note below states which point that is.
public final class ScreenSharingRtcEventLogDiagnostic {
  /// Requested window in seconds relative to media start (measured seconds).
  public struct Window: Equatable, Sendable {
    public static let maximumDurationSeconds = 120.0
    public let beginSeconds: Double
    public let durationSeconds: Double
    public var endSeconds: Double { beginSeconds + durationSeconds }
    public init(beginSeconds: Double, durationSeconds: Double) throws {
      guard beginSeconds.isFinite, durationSeconds.isFinite, beginSeconds >= 0,
        (1...Self.maximumDurationSeconds).contains(durationSeconds)
      else {
        throw ScreenSharingError.invalid(
          "RTC event log window needs begin >= 0 and a duration of 1...\(Int(Self.maximumDurationSeconds)) seconds.")
      }
      self.beginSeconds = beginSeconds
      self.durationSeconds = durationSeconds
    }
  }

  /// Injectable boundaries: the clock and the two synchronous peer calls.
  public struct Boundaries {
    public let clock: () -> Int64
    public let start: (_ path: String, _ maxSizeBytes: Int64) -> Bool
    /// Returns true only when the native stop API was actually invoked (a closed peer reports false).
    public let stop: () -> Bool
    public init(
      clock: @escaping () -> Int64, start: @escaping (String, Int64) -> Bool, stop: @escaping () -> Bool
    ) {
      self.clock = clock
      self.start = start
      self.stop = stop
    }
  }

  /// Which peer the log belongs to. A sender log stamps an outgoing packet after a successful `SendRtp`, which either
  /// sends directly when it is already on the network thread or queues a task there, returning true either way: the
  /// post-pacer TRANSPORT HAND-OFF, never socket or NIC egress. A receiver log stamps a packet where the video receiver
  /// logs it, which is not NIC arrival.
  public enum Role: String, Encodable, Sendable {
    case receiver
    case sender
  }

  public enum State: String, Encodable, Sendable {
    /// Before the first tick at or after the requested begin.
    case waiting
    /// Options requested the log but the probe failed before the receiver/log were constructed; no API call.
    case notInitialized
    /// The exclusive output reservation failed at start time (an entry appeared after preflight); no API call.
    case startRefused
    /// The start call returned true; the stop call has not happened.
    case started
    /// The start call returned false; no stop call will ever be made.
    case startFailed
    /// A successful start was stopped exactly once: the native stop API was invoked.
    case stopped
    /// A stop was attempted once but the boundary reported the native API was not invoked (peer already closed).
    case stopSkipped
    /// Closed (normal end, failure, cancellation or early close) before any start call, or the first
    /// start opportunity was already past the requested end; no API call was made.
    case closedWithoutStart
  }

  /// The final record; identical in the report and the failure record.
  public struct Record: Encodable, Equatable, Sendable {
    public let kind: String
    public let role: String
    public let clock: String
    public let path: String
    public let maxSizeBytes: Int64
    public let requestedBeginSeconds: Double
    public let requestedDurationSeconds: Double
    public let requestedEndSeconds: Double
    public let state: State
    public let final: Bool
    /// The exclusive owned-file reservation made immediately before the start API ("reserved" or the refusal).
    public let outputReservation: String?
    public let startApiInvoked: Bool
    /// Measured seconds (the probe's media clock) at the tick that made the start call; nil = no call.
    public let startAttemptedAtMeasuredSeconds: Double?
    public let startCallBeforeNs: Int64?
    public let startCallAfterNs: Int64?
    public let startReturned: Bool?
    public let stopAttemptedAtMeasuredSeconds: Double?
    public let stopCallBeforeNs: Int64?
    public let stopCallAfterNs: Int64?
    /// A stop was attempted (bracket taken); `stopApiInvoked` says whether the native API actually ran.
    public let stopAttempted: Bool
    public let stopApiInvoked: Bool
    public let stoppedSuccessfulStart: Bool
    public let closeReason: String?
    public let notes: [String]

    /// The record for a requested log whose diagnostic was never constructed (failure before the receiver/log).
    public static func notInitialized(
      beginSeconds: Double, durationSeconds: Double, path: String, maxSizeBytes: Int64, reason: String,
      role: Role = .receiver
    ) -> Record {
      Record(
        kind: ScreenSharingRtcEventLogDiagnostic.kind, role: role.rawValue,
        clock: "CACurrentMediaTime nanoseconds (Int64)", path: path,
        maxSizeBytes: maxSizeBytes, requestedBeginSeconds: beginSeconds, requestedDurationSeconds: durationSeconds,
        requestedEndSeconds: beginSeconds + durationSeconds, state: .notInitialized, final: true,
        outputReservation: nil, startApiInvoked: false, startAttemptedAtMeasuredSeconds: nil, startCallBeforeNs: nil,
        startCallAfterNs: nil, startReturned: nil, stopAttemptedAtMeasuredSeconds: nil, stopCallBeforeNs: nil,
        stopCallAfterNs: nil, stopAttempted: false, stopApiInvoked: false, stoppedSuccessfulStart: false,
        closeReason: reason + "; no API call", notes: ScreenSharingRtcEventLogDiagnostic.notes(for: role))
    }
  }

  public static let fixedMaxSizeBytes: Int64 = 8 * 1024 * 1024
  public static let kind = "codevisor.rtcEventLogDiagnostic"
  /// The one supported clock: CACurrentMediaTime in nanoseconds (the audit, viewer origin and observer clock).
  public static func defaultClock() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000_000) }
  public static let notes = [
    "bracket A: CACurrentMediaTime nanoseconds read immediately before and after the synchronous start and stop API calls; the pinned WebRTC start reads its own clock before posting the begin event and stop waits for the task that stamps the end event, so each bracket encloses that event's true instant",
    "clock contract for the offline oracle: a nonnegative logged integer t_ms represents [t, t+1) ms of the log clock; a bracket bounds the log-to-CA offset to [beforeNs - (t+1)*1e6, afterNs - t*1e6]; start and stop bounds must each be finite, narrow and mutually consistent, never averaged",
    "WebRTC keeps a bounded pre-start history that is written after the begin event: the file is not exclusively the requested window",
    "startReturned true means the log accepted its output, not that the file is complete; stop returns void, so an absent end event is an offline finding (8 MiB cap reached, a write failure, or an abnormal stop)",
    "the output path is reserved as an owned empty file (O_EXCL) immediately before the start API, which may then overwrite only that reserved file; an entry appearing after option preflight refuses the start and the API is not invoked; on a false start the empty reservation stays (it holds no evidence)",
    "requested and actual bounds are recorded separately; a late tick or a missed stop is stated as such",
    "packet timestamps are this role's own WebRTC logging point (see the role note), never a socket or NIC boundary; a marker bit is not a decodable frame; no FrameDecodedEvents join; parse success, byte-cap completeness and packet or audit coverage are separate offline judgements, not a media verdict",
  ]

  /// Role-specific note appended to the role-neutral notes.
  public static func notes(for role: Role) -> [String] {
    switch role {
    case .receiver:
      notes + [
        "receiver log: incoming packet events are stamped where the video receiver logs the packet "
          + "(RtpVideoStreamReceiver2::OnRtpPacket), which is not NIC arrival"
      ]
    case .sender:
      notes + [
        "sender log: outgoing packet events are stamped after a successful SendRtp, which either sends directly when it is already on the network thread or queues a task there and returns true either way: the post-pacer TRANSPORT HAND-OFF, never socket/NIC egress; any network-thread queueing and send, the OS, the network and the receiver's ingress scheduling are downstream unknowns"
      ]
    }
  }

  public let window: Window
  public let path: String
  public let maxSizeBytes: Int64
  public let role: Role
  private let boundaries: Boundaries
  private let lock = NSLock()
  private var state = State.waiting
  private var final = false
  private var startAttemptedAt: Double?
  private var startBefore: Int64?
  private var startAfter: Int64?
  private var startReturned: Bool?
  private var stopAttemptedAt: Double?
  private var stopBefore: Int64?
  private var stopAfter: Int64?
  private var stopInvoked = false
  private var reservation: String?
  private var closeReason: String?

  public init(
    window: Window, path: String, maxSizeBytes: Int64 = ScreenSharingRtcEventLogDiagnostic.fixedMaxSizeBytes,
    role: Role = .receiver, boundaries: Boundaries
  ) {
    self.window = window
    self.path = path
    self.maxSizeBytes = maxSizeBytes
    self.role = role
    self.boundaries = boundaries
  }

  /// Option-time preflight: refuses any existing entry at the raw output path,
  /// including a dangling symlink, and any lstat error other than plain
  /// absence: prior evidence is never truncated (WebRTC opens the path "wb").
  public static func checkOutputPath(_ path: String) throws {
    var status = stat()
    if lstat(path, &status) == 0 {
      throw ScreenSharingError.invalid(
        "RTC event log output already exists (file, directory or symlink): \(path). Use a fresh report stem.")
    }
    guard errno == ENOENT else {
      throw ScreenSharingError.invalid(
        "RTC event log output path cannot be checked (\(String(cString: strerror(errno)))): \(path).")
    }
  }

  /// Start-time exclusive ownership: creates the raw output as an owned empty
  /// file with O_CREAT|O_EXCL (fails on any existing entry, including a
  /// dangling symlink) so the start API may overwrite only this reserved
  /// file. Nothing is ever deleted.
  public static func reserveOutputPath(_ path: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw ScreenSharingError.invalid(
        "RTC event log output could not be reserved exclusively (\(String(cString: strerror(errno)))): \(path).")
    }
    _ = Darwin.close(descriptor)  // the POSIX close, not this class's close(measuredSeconds:reason:)
  }

  /// The measurement loop's sleep: at most `tickInterval`, at most the
  /// remaining duration, and no later than the next requested boundary.
  public static func sleepSeconds(
    measured: Double, remaining: Double, nextBoundary: Double?, tickInterval: Double = 1
  ) -> Double {
    var seconds = min(tickInterval, remaining)
    if let nextBoundary, nextBoundary > measured { seconds = min(seconds, nextBoundary - measured) }
    return max(0.001, seconds)
  }

  /// The next measured second at which a tick has work: the requested begin
  /// while waiting, the requested end while started, nil once final.
  public func nextBoundarySeconds() -> Double? {
    lock.withLock {
      switch state {
      case .waiting: window.beginSeconds
      case .started: window.endSeconds
      case .notInitialized, .startRefused, .startFailed, .stopped, .stopSkipped, .closedWithoutStart: nil
      }
    }
  }

  /// One measurement tick. Makes at most one API call per tick: the start at
  /// the first tick at or after the requested begin, the stop at the first
  /// tick at or after the requested end. A first opportunity that is already
  /// past the end never starts.
  public func tick(measuredSeconds: Double) {
    lock.withLock {
      guard !final else { return }
      switch state {
      case .waiting where measuredSeconds >= window.endSeconds:
        state = .closedWithoutStart
        closeReason =
          "first start opportunity at \(measuredSeconds) s was already past the requested end \(window.endSeconds) s; no start call"
        final = true
      case .waiting where measuredSeconds >= window.beginSeconds:
        do {
          try Self.reserveOutputPath(path)
          reservation = "reserved: owned empty file created O_EXCL immediately before the start API"
        } catch {
          reservation = "refused: \(error.localizedDescription)"
          state = .startRefused
          closeReason = "output reservation failed at \(measuredSeconds) s; start API not invoked"
          final = true
          return
        }
        startAttemptedAt = measuredSeconds
        startBefore = boundaries.clock()
        let returned = boundaries.start(path, maxSizeBytes)
        startAfter = boundaries.clock()
        startReturned = returned
        if returned {
          state = .started
        } else {
          state = .startFailed
          closeReason = "start returned false at \(measuredSeconds) s; no stop call"
          final = true
        }
      case .started where measuredSeconds >= window.endSeconds:
        stopLocked(measuredSeconds: measuredSeconds, reason: "requested window end")
      default:
        break
      }
    }
  }

  /// Normal completion: stops a started log exactly once; a log never started is closed without a call.
  public func finish(measuredSeconds: Double) { close(measuredSeconds: measuredSeconds, reason: "normal completion") }

  /// Failure, cancellation or early close: the same once-only rules; repeated calls change nothing.
  public func closeEarly(measuredSeconds: Double?, reason: String) {
    close(measuredSeconds: measuredSeconds, reason: "early close: " + reason)
  }

  private func close(measuredSeconds: Double?, reason: String) {
    lock.withLock {
      guard !final else { return }
      switch state {
      case .started:
        stopLocked(measuredSeconds: measuredSeconds, reason: reason)
      case .waiting:
        state = .closedWithoutStart
        closeReason = reason + "; no start call was made"
        final = true
      case .notInitialized, .startRefused, .startFailed, .stopped, .stopSkipped, .closedWithoutStart:
        break
      }
    }
  }

  private func stopLocked(measuredSeconds: Double?, reason: String) {
    stopAttemptedAt = measuredSeconds
    stopBefore = boundaries.clock()
    stopInvoked = boundaries.stop()
    stopAfter = boundaries.clock()
    if stopInvoked {
      state = .stopped
      closeReason = reason
    } else {
      state = .stopSkipped
      closeReason = reason + "; the stop boundary reported the native API was not invoked (peer already closed)"
    }
    final = true
  }

  public var record: Record {
    lock.withLock {
      Record(
        kind: Self.kind, role: role.rawValue, clock: "CACurrentMediaTime nanoseconds (Int64)", path: path,
        maxSizeBytes: maxSizeBytes,
        requestedBeginSeconds: window.beginSeconds, requestedDurationSeconds: window.durationSeconds,
        requestedEndSeconds: window.endSeconds, state: state, final: final, outputReservation: reservation,
        startApiInvoked: startBefore != nil,
        startAttemptedAtMeasuredSeconds: startAttemptedAt, startCallBeforeNs: startBefore, startCallAfterNs: startAfter,
        startReturned: startReturned, stopAttemptedAtMeasuredSeconds: stopAttemptedAt, stopCallBeforeNs: stopBefore,
        stopCallAfterNs: stopAfter, stopAttempted: stopBefore != nil, stopApiInvoked: stopInvoked,
        stoppedSuccessfulStart: state == .stopped, closeReason: closeReason, notes: Self.notes(for: role))
    }
  }
}
