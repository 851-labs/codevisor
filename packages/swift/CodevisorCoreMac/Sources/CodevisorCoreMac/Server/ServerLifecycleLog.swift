import CodevisorClient
import CodevisorCore
import Foundation

public struct ServerLifecycleLog: Sendable {
  private let fileURL: URL?
  private let processIdentifier: Int32

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

public struct StepClock {
  private let clock = ContinuousClock()
  private let start: ContinuousClock.Instant
  private var last: ContinuousClock.Instant

  public init() {
    start = clock.now
    last = start
  }

  public mutating func lap() -> Int {
    let now = clock.now
    defer { last = now }
    return Int((now - last) / .milliseconds(1))
  }

  public var totalMilliseconds: Int {
    Int((clock.now - start) / .milliseconds(1))
  }
}

public enum LaunchctlPrintOutput {
  public static func isRunning(_ result: CommandResult) -> Bool? {
    if result.exitCode == 3 || result.exitCode == 113 { return false }
    guard result.exitCode == 0 else { return nil }
    if let pid = pid(in: result.standardOutput), pid > 0 { return true }
    let lines = result.standardOutput.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
    if lines.contains("state = not running") || lines.contains("state = waiting") { return false }
    return nil
  }

  public static func pid(in output: String) -> Int? {
    for line in output.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("pid = ") else { continue }
      return Int(trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces))
    }
    return nil
  }
}
