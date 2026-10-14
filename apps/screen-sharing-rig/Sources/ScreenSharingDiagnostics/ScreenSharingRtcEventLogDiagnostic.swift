import ScreenSharing
import Foundation
import QuartzCore

package final class ScreenSharingRtcEventLogDiagnostic {
  package struct Window: Equatable, Sendable {
    package static let maximumDurationSeconds = 120.0
    package let beginSeconds: Double
    package let durationSeconds: Double
    package var endSeconds: Double { beginSeconds + durationSeconds }
    package init(beginSeconds: Double, durationSeconds: Double) throws {
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

  package struct Boundaries {
    package let clock: () -> Int64
    package let start: (_ path: String, _ maxSizeBytes: Int64) -> Bool
    package let stop: () -> Bool
    package init(
      clock: @escaping () -> Int64, start: @escaping (String, Int64) -> Bool, stop: @escaping () -> Bool
    ) {
      self.clock = clock
      self.start = start
      self.stop = stop
    }
  }

  package enum Role: String, Encodable, Sendable {
    case receiver
    case sender
  }

  package enum State: String, Encodable, Sendable {
    case waiting
    case notInitialized
    case startRefused
    case started
    case startFailed
    case stopped
    case stopSkipped
    case closedWithoutStart
  }

  package struct Record: Encodable, Equatable, Sendable {
    package let kind: String
    package let role: String
    package let clock: String
    package let path: String
    package let maxSizeBytes: Int64
    package let requestedBeginSeconds: Double
    package let requestedDurationSeconds: Double
    package let requestedEndSeconds: Double
    package let state: State
    package let final: Bool
    package let outputReservation: String?
    package let startApiInvoked: Bool
    package let startAttemptedAtMeasuredSeconds: Double?
    package let startCallBeforeNs: Int64?
    package let startCallAfterNs: Int64?
    package let startReturned: Bool?
    package let stopAttemptedAtMeasuredSeconds: Double?
    package let stopCallBeforeNs: Int64?
    package let stopCallAfterNs: Int64?
    package let stopAttempted: Bool
    package let stopApiInvoked: Bool
    package let stoppedSuccessfulStart: Bool
    package let closeReason: String?
    package let notes: [String]

    package static func notInitialized(
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

  package static let fixedMaxSizeBytes: Int64 = 8 * 1024 * 1024
  package static let kind = "codevisor.rtcEventLogDiagnostic"
  package static func defaultClock() -> Int64 { Int64(CACurrentMediaTime() * 1_000_000_000) }
  package static let notes = [
    "bracket A: CACurrentMediaTime nanoseconds read immediately before and after the synchronous start and stop API calls; the pinned WebRTC start reads its own clock before posting the begin event and stop waits for the task that stamps the end event, so each bracket encloses that event's true instant",
    "clock contract for the offline oracle: a nonnegative logged integer t_ms represents [t, t+1) ms of the log clock; a bracket bounds the log-to-CA offset to [beforeNs - (t+1)*1e6, afterNs - t*1e6]; start and stop bounds must each be finite, narrow and mutually consistent, never averaged",
    "WebRTC keeps a bounded pre-start history that is written after the begin event: the file is not exclusively the requested window",
    "startReturned true means the log accepted its output, not that the file is complete; stop returns void, so an absent end event is an offline finding (8 MiB cap reached, a write failure, or an abnormal stop)",
    "the output path is reserved as an owned empty file (O_EXCL) immediately before the start API, which may then overwrite only that reserved file; an entry appearing after option preflight refuses the start and the API is not invoked; on a false start the empty reservation stays (it holds no evidence)",
    "requested and actual bounds are recorded separately; a late tick or a missed stop is stated as such",
    "packet timestamps are this role's own WebRTC logging point (see the role note), never a socket or NIC boundary; a marker bit is not a decodable frame; no FrameDecodedEvents join; parse success, byte-cap completeness and packet or audit coverage are separate offline judgements, not a media verdict",
  ]

  package static func notes(for role: Role) -> [String] {
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

  package let window: Window
  package let path: String
  package let maxSizeBytes: Int64
  package let role: Role
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

  package init(
    window: Window, path: String, maxSizeBytes: Int64 = ScreenSharingRtcEventLogDiagnostic.fixedMaxSizeBytes,
    role: Role = .receiver, boundaries: Boundaries
  ) {
    self.window = window
    self.path = path
    self.maxSizeBytes = maxSizeBytes
    self.role = role
    self.boundaries = boundaries
  }

  package static func checkOutputPath(_ path: String) throws {
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

  package static func reserveOutputPath(_ path: String) throws {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw ScreenSharingError.invalid(
        "RTC event log output could not be reserved exclusively (\(String(cString: strerror(errno)))): \(path).")
    }
    _ = Darwin.close(descriptor)
  }

  package static func sleepSeconds(
    measured: Double, remaining: Double, nextBoundary: Double?, tickInterval: Double = 1
  ) -> Double {
    var seconds = min(tickInterval, remaining)
    if let nextBoundary, nextBoundary > measured { seconds = min(seconds, nextBoundary - measured) }
    return max(0.001, seconds)
  }

  package func nextBoundarySeconds() -> Double? {
    lock.withLock {
      switch state {
      case .waiting: window.beginSeconds
      case .started: window.endSeconds
      case .notInitialized, .startRefused, .startFailed, .stopped, .stopSkipped, .closedWithoutStart: nil
      }
    }
  }

  package func tick(measuredSeconds: Double) {
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

  package func finish(measuredSeconds: Double) { close(measuredSeconds: measuredSeconds, reason: "normal completion") }

  package func closeEarly(measuredSeconds: Double?, reason: String) {
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

  package var record: Record {
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
