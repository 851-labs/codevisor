import CodevisorClient
import CodevisorCore
import Foundation

/// One timeline for the local server. Every lifecycle step the app takes —
/// probing, registering the LaunchAgent, waiting for health, draining and
/// stopping for an update — is appended to `server.log`, the same file the
/// agent script and the server process write to, tagged `[app <pid>]`. A
/// stuck or failed start then reads as one ordered story: the old app's
/// shutdown, the new app's steps, the agent script, the server's own boot.
///
/// Lines are mirrored to the unified log (`Log.server`) at default level so
/// they persist there too, but the file is the durable copy: unified log
/// retention on a busy machine is about a day.
public struct ServerLifecycleLog: Sendable {
  private let fileURL: URL?
  private let processIdentifier: Int32

  /// The production timeline: `~/.codevisor/logs/server.log`.
  public static let `default` = ServerLifecycleLog(
    fileURL: CodevisorAppVariant.serverLogsDirectoryURL().appendingPathComponent("server.log")
  )

  public init(fileURL: URL?, processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) {
    self.fileURL = fileURL
    self.processIdentifier = processIdentifier
  }

  public func note(_ message: String) {
    Log.server.log("\(message, privacy: .public)")
    append(message)
  }

  public func error(_ message: String) {
    Log.server.error("\(message, privacy: .public)")
    append("ERROR \(message)")
  }

  /// A broken expectation worth finding first in the log (a watchdog
  /// firing, a step that never returned).
  public func fault(_ message: String) {
    Log.server.fault("\(message, privacy: .public)")
    append("FAULT \(message)")
  }

  private func append(_ message: String) {
    guard let fileURL else { return }
    let line = "[\(Self.timestamp())] [app \(processIdentifier)] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // O_APPEND: each line lands atomically after whatever the server or the
    // agent script wrote last, so interleaved writers never corrupt a line.
    let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { return }
    defer { close(descriptor) }
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      _ = write(descriptor, base, buffer.count)
    }
  }

  private static func timestamp() -> String {
    Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: true))
  }
}

/// Elapsed-time bookkeeping for a multi-step operation whose steps are
/// logged as they complete: "step (elapsed ms)".
public struct StepClock {
  private let clock = ContinuousClock()
  private let start: ContinuousClock.Instant
  private var last: ContinuousClock.Instant

  public init() {
    start = clock.now
    last = start
  }

  /// Milliseconds since the previous mark, then resets the mark.
  public mutating func lap() -> Int {
    let now = clock.now
    defer { last = now }
    return Int((now - last) / .milliseconds(1))
  }

  public var totalMilliseconds: Int {
    Int((clock.now - start) / .milliseconds(1))
  }
}

/// Reads the pieces of `launchctl print <domain>/<label>` output the app
/// cares about. launchctl is the only public view of a launchd job's live
/// process; SMAppService reports registration, not liveness.
public enum LaunchctlPrintOutput {
  /// The job's live process id, or nil while the job has no process.
  public static func pid(in output: String) -> Int? {
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("pid = ") else { continue }
      return Int(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }
}
