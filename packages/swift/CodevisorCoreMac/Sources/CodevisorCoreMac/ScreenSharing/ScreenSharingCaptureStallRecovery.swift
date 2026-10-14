import Darwin
import Foundation
import ScreenSharing

@MainActor
public struct ScreenSharingCaptureStallRecovery {
  public enum Outcome: Equatable, Sendable {
    case healthy
    case recovered(restartedDaemon: Bool)
    case failed
  }

  static let grace: Duration = .seconds(3)
  static let pollInterval: Duration = .milliseconds(250)
  static let daemonRespawn: Duration = .seconds(1)
  static let daemonRestartInterval: TimeInterval = 60
  static let startTimeout: Duration = .seconds(5)

  var callbacks: () -> Int
  var restartCapture: () async throws -> Void
  var restartDaemon: () -> Bool
  var lastDaemonRestart: () -> TimeInterval?
  var now: () -> TimeInterval
  var sleep: @MainActor (Duration) async throws -> Void
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

  private static var lastDaemonRestartUptime: TimeInterval?

  public static func live(
    metrics: ScreenSharingMetrics, callbacks: (() -> Int)? = nil, restartCapture: @escaping () async throws -> Void,
    log: @escaping (String) -> Void, onStalled: @escaping () -> Void
  ) -> Self {
    let uptime = { ProcessInfo.processInfo.systemUptime }
    return Self(
      callbacks: callbacks ?? { activity(metrics.counters()) }, restartCapture: restartCapture,
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

  public static func activity(_ counters: [String: Int]) -> Int {
    ScreenSharingCaptureCallbackAccounting.callbackTotal(counters: counters) + counters["capturedFrames", default: 0]
  }

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

  public func start(_ start: @escaping @MainActor (_ retry: Bool) async throws -> Void) async throws {
    let attempt = Task { @MainActor in try await start(false) }
    try await withTaskCancellationHandler {
      if await Self.finishes(attempt, within: Self.startTimeout, sleep: sleep) { return try await attempt.value }
      onStalled()
      guard mayRestartDaemon, restartDaemon() else {
        return try await Self.value(of: attempt, within: Self.startTimeout, sleep: sleep)
      }
      if await Self.finishes(attempt, within: Self.daemonRespawn, sleep: sleep), case .success = await attempt.result {
        return
      }
      attempt.cancel()
      try Task.checkCancellation()
      try await Self.value(of: Task { @MainActor in try await start(true) }, within: Self.startTimeout, sleep: sleep)
    } onCancel: {
      attempt.cancel()
    }
  }

  public nonisolated static let stuck = ScreenSharingError.unavailable(
    "The host Mac's screen capture isn't responding. Try again in a minute.")

  private static func value(
    of task: Task<Void, any Error>, within timeout: Duration,
    sleep: @escaping @MainActor (Duration) async throws -> Void
  ) async throws {
    try await withTaskCancellationHandler {
      guard await finishes(task, within: timeout, sleep: sleep) else {
        task.cancel()
        try Task.checkCancellation()
        throw stuck
      }
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static let stopTimeout: Duration = .seconds(3)

  public static func stop(
    _ stop: @escaping @MainActor () async throws -> Void,
    sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) async -> Bool {
    await finishes(Task { @MainActor in try await stop() }, within: stopTimeout, sleep: sleep)
  }

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

  private func delivers(after baseline: Int) async throws -> Bool {
    let polls = Int(Self.grace / Self.pollInterval)
    for _ in 0..<polls {
      if callbacks() > baseline { return true }
      try await sleep(Self.pollInterval)
    }
    return callbacks() > baseline
  }
}

enum ScreenSharingCaptureDaemon {
  static let name = "replayd"

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
    var buffer = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
    let length = proc_name(pid, &buffer, UInt32(buffer.count))
    return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
  }

  static func descriptorCount(_ pid: pid_t) -> Int? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return nil }
    return Int(bytes) / MemoryLayout<proc_fdinfo>.size
  }

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
