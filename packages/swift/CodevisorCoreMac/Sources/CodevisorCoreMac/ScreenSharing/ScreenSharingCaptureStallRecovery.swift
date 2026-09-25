import Darwin
import Foundation
import ScreenSharing

/// A capture that starts and then delivers nothing (851-2385). macOS's capture
/// daemon, `replayd`, leaks descriptors with every ScreenCaptureKit stream; once
/// it runs out, each new stream starts without an error and never calls back.
/// Nothing but restarting `replayd` fixes that, and the host's user can't be
/// expected to know it.
///
/// ScreenCaptureKit calls back at least once as soon as a stream starts (the
/// first complete frame), even for a still screen, and may stay silent after
/// that while nothing changes. So only a stream that has not called back at
/// all is taken for stalled; a quiet stream that already delivered is not.
///
/// The recovery, in order: restart the capture; if it still delivers nothing,
/// kill the user's own `replayd` (launchd starts a fresh one on the next
/// request) and restart the capture again. Killing it interrupts every other
/// screen recording on this Mac, so it happens only for a stalled capture and at
/// most once per `daemonRestartInterval` in this process.
@MainActor
public struct ScreenSharingCaptureStallRecovery {
  public enum Outcome: Equatable, Sendable {
    /// The capture delivered without any help.
    case healthy
    /// Delivering again; `restartedDaemon` when it took restarting `replayd`.
    case recovered(restartedDaemon: Bool)
    /// Still nothing after every step allowed.
    case failed
  }

  /// How long a started capture may stay silent before it counts as stalled.
  static let grace: Duration = .seconds(3)
  static let pollInterval: Duration = .milliseconds(250)
  /// Time for launchd to take the killed daemon's place before the next start.
  static let daemonRespawn: Duration = .seconds(1)
  /// The shortest time between two `replayd` restarts by this process.
  static let daemonRestartInterval: TimeInterval = 600
  /// How long starting a capture may take. A wedged `replayd` (on tuftlord, a stopped one) never
  /// answers, and the start waits forever instead of failing.
  static let startTimeout: Duration = .seconds(5)

  /// Every sample callback the capture has made so far (a counter that only grows).
  var callbacks: () -> Int
  /// Stops the capture and starts it again with the session's configuration.
  var restartCapture: () async throws -> Void
  /// Kills the current user's capture daemon; false when there was none to kill.
  var restartDaemon: () -> Bool
  /// When `replayd` was last restarted by this process, and the clock to compare with.
  var lastDaemonRestart: () -> TimeInterval?
  var now: () -> TimeInterval
  var sleep: @MainActor (Duration) async throws -> Void
  /// Called once, when the capture is first found stalled.
  var onStalled: () -> Void = {}

  init(
    callbacks: @escaping () -> Int, restartCapture: @escaping () async throws -> Void,
    restartDaemon: @escaping () -> Bool, lastDaemonRestart: @escaping () -> TimeInterval?,
    now: @escaping () -> TimeInterval, sleep: @escaping @MainActor (Duration) async throws -> Void,
    onStalled: @escaping () -> Void = {}
  ) {
    self.callbacks = callbacks; self.restartCapture = restartCapture; self.restartDaemon = restartDaemon
    self.lastDaemonRestart = lastDaemonRestart; self.now = now; self.sleep = sleep; self.onStalled = onStalled
  }

  /// When this process last restarted `replayd`, on the uptime clock; shared by every session.
  private static var lastDaemonRestartUptime: TimeInterval?

  /// The real thing: counts `metrics`' capture callbacks and delivered frames, kills the
  /// user's `replayd` for real (logging its descriptor count first) and sleeps for real.
  /// `callbacks` overrides counting from `metrics`, for a stream whose callbacks aren't in them
  /// (the Computer Use preview's).
  public static func live(
    metrics: ScreenSharingMetrics, callbacks: (() -> Int)? = nil, restartCapture: @escaping () async throws -> Void,
    log: @escaping (String) -> Void, onStalled: @escaping () -> Void
  ) -> Self {
    let uptime = { ProcessInfo.processInfo.systemUptime }
    return Self(
      callbacks: callbacks ?? { activity(metrics.snapshot().counters) }, restartCapture: restartCapture,
      restartDaemon: {
        let daemons = ScreenSharingCaptureDaemon.processes()
        let descriptors = daemons.map { ScreenSharingCaptureDaemon.descriptorCount($0).map(String.init) ?? "?" }
        guard ScreenSharingCaptureDaemon.kill() else {
          log("capture stalled; no replayd to restart")
          return false
        }
        lastDaemonRestartUptime = uptime()
        metrics.increment("captureDaemonRestarts")
        log("capture stalled; restarted replayd (pid \(daemons), descriptors \(descriptors))")
        return true
      }, lastDaemonRestart: { lastDaemonRestartUptime }, now: uptime,
      sleep: { try await Task.sleep(for: $0) }, onStalled: onStalled)
  }

  /// Everything a live capture makes: every sample callback, plus the frames handed to the sender
  /// (a source other than ScreenCaptureKit only has those). Only grows.
  public static func activity(_ counters: [String: Int]) -> Int {
    ScreenSharingCaptureCallbackAccounting.callbackTotal(counters: counters) + counters["capturedFrames", default: 0]
  }

  /// Watches a capture that has just started (its callbacks counted before the start were
  /// `baseline`) and recovers it if it stays silent. Throws only when cancelled.
  public func run(baseline: Int) async throws -> Outcome {
    if try await delivers(after: baseline) { return .healthy }
    onStalled()
    if try await restartDelivers() { return .recovered(restartedDaemon: false) }
    guard mayRestartDaemon, restartDaemon() else { return .failed }
    try await sleep(Self.daemonRespawn)
    return try await restartDelivers() ? .recovered(restartedDaemon: true) : .failed
  }

  private var mayRestartDaemon: Bool {
    guard let last = lastDaemonRestart() else { return true }
    return now() - last >= Self.daemonRestartInterval
  }

  /// Starts a capture with `start`, which a wedged `replayd` can leave waiting forever. If it
  /// hasn't returned within `startTimeout`, the daemon is restarted (same rate limit). The waiting
  /// start may then complete; if it fails, or is still waiting after `daemonRespawn` (on tuftlord,
  /// ScreenCaptureKit dropped the killed daemon's reply and the start never returned), it's
  /// abandoned and `start(true)` runs on the fresh daemon: `true` asks it to reset what the
  /// abandoned attempt left. Cancelling the caller cancels the start.
  public func start(_ start: @escaping @MainActor (_ retry: Bool) async throws -> Void) async throws {
    let attempt = Task { @MainActor in try await start(false) }
    try await withTaskCancellationHandler {
      if await Self.finishes(attempt, within: Self.startTimeout, sleep: sleep) { return try await attempt.value }
      onStalled()
      guard mayRestartDaemon, restartDaemon() else { return try await attempt.value }
      if await Self.finishes(attempt, within: Self.daemonRespawn, sleep: sleep), case .success = await attempt.result {
        return
      }
      attempt.cancel()
      try Task.checkCancellation()
      try await start(true)
    } onCancel: {
      attempt.cancel()
    }
  }

  /// Stopping a capture waits on `replayd` too; a wedged daemon must not keep a session from
  /// ending (and the host busy). Waits for `stop` at most `stopTimeout`, then moves on.
  static let stopTimeout: Duration = .seconds(3)

  public static func stop(
    _ stop: @escaping @MainActor () async throws -> Void,
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> Bool {
    await finishes(Task { @MainActor in try await stop() }, within: stopTimeout, sleep: sleep)
  }

  /// Whether `task` finishes (either way) before `sleep(timeout)` does.
  private static func finishes(
    _ task: Task<Void, any Error>, within timeout: Duration, sleep: @escaping @MainActor (Duration) async throws -> Void
  ) async -> Bool {
    let race = Race()
    return await withCheckedContinuation { continuation in
      race.continuation = continuation
      race.timer = Task { @MainActor in
        guard (try? await sleep(timeout)) != nil else { return }
        race.finish(false)
      }
      Task { @MainActor in
        _ = await task.result
        race.finish(true)
      }
    }
  }

  @MainActor private final class Race {
    var continuation: CheckedContinuation<Bool, Never>?
    var timer: Task<Void, Never>?
    func finish(_ value: Bool) {
      guard let continuation else { return }
      self.continuation = nil
      timer?.cancel()
      continuation.resume(returning: value)
    }
  }

  private func restartDelivers() async throws -> Bool {
    let baseline = callbacks()
    do {
      try await restartCapture()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return false
    }
    return try await delivers(after: baseline)
  }

  /// Whether the capture calls back within `grace`, checking every `pollInterval`.
  private func delivers(after baseline: Int) async throws -> Bool {
    let polls = Int(Self.grace / Self.pollInterval)
    for _ in 0..<polls {
      if callbacks() > baseline { return true }
      try await sleep(Self.pollInterval)
    }
    return callbacks() > baseline
  }
}

/// The current user's `replayd`, found and killed through libproc: no
/// subprocess, and never another user's daemon.
enum ScreenSharingCaptureDaemon {
  static let name = "replayd"

  /// The current user's processes called `name` (by default, its `replayd`).
  static func processes(named name: String = name) -> [pid_t] {
    let uid = getuid()
    let capacity = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0) / Int32(MemoryLayout<pid_t>.size) + 32
    guard capacity > 32 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(capacity))
    let bytes = pids.withUnsafeMutableBytes {
      proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
    }
    return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { pid in
      pid > 0 && processName(pid) == name && owner(of: pid) == uid
    }
  }

  static func processName(_ pid: pid_t) -> String? {
    // proc_name wants room for the full name (2 × MAXCOMLEN); a smaller buffer gets nothing.
    var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
  }

  /// Open descriptors of `pid`, or nil when it can't be read; a leaking daemon holds hundreds.
  static func descriptorCount(_ pid: pid_t) -> Int? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return nil }
    return Int(bytes) / MemoryLayout<proc_fdinfo>.size
  }

  /// SIGKILL: `replayd` ignores SIGTERM, and `launchctl` can't restart it under SIP.
  /// Returns whether a daemon was killed.
  static func kill() -> Bool {
    processes().reduce(false) { killed, pid in Darwin.kill(pid, SIGKILL) == 0 || killed }
  }

  private static func owner(of pid: pid_t) -> uid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_uid
  }
}
