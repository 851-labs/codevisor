import CodevisorCore
import Darwin
import Foundation

public enum LegacyServerJobRetirementError: LocalizedError, Equatable {
  case commandFailed(label: String, exitCode: Int32, message: String)

  public var errorDescription: String? {
    switch self {
    case let .commandFailed(label, exitCode, message):
      let detail = message.isEmpty ? "launchctl exited with status \(exitCode)" : message
      return "The obsolete Codevisor server job \(label) could not be stopped: \(detail)"
    }
  }
}

public struct LegacyServerJobRetirer: Sendable {
  public static let labels = [
    "com.851labs.codevisor-recovery",
    "com.851labs.herdman-recovery",
    "com.851labs.HerdMan-recovery",
  ]

  private let runner: any CommandRunner
  private let userID: UInt32
  private let clock: any Clock<Duration>
  private let commandTimeout: Duration
  private let lifecycleLog: ServerLifecycleLog

  public init(
    runner: any CommandRunner = ProcessCommandRunner(),
    userID: UInt32 = getuid(),
    commandTimeout: Duration = .seconds(5),
    lifecycleLog: ServerLifecycleLog = .default,
    clock: any Clock<Duration> = ContinuousClock()
  ) {
    self.lifecycleLog = lifecycleLog
    self.clock = clock
    self.runner = runner
    self.userID = userID
    self.commandTimeout = commandTimeout
  }

  public func retire() async throws {
    for label in Self.labels {
      let target = "gui/\(userID)/\(label)"
      lifecycleLog.note("launchd: retiring obsolete job \(target)")
      let result = try await runner.run(
        executableURL: URL(fileURLWithPath: "/bin/launchctl"),
        arguments: ["bootout", target],
        environment: nil,
        timeout: commandTimeout,
        clock: clock
      )
      lifecycleLog.note("launchd: cleanup \(label) exited \(result.exitCode)")
      guard result.exitCode == 0 || Self.meansServiceWasMissing(result) else {
        let message = [result.standardError, result.standardOutput]
          .joined(separator: "\n")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        throw LegacyServerJobRetirementError.commandFailed(
          label: label,
          exitCode: result.exitCode,
          message: message
        )
      }
    }
  }

  private static func meansServiceWasMissing(_ result: CommandResult) -> Bool {
    if result.exitCode == 3 || result.exitCode == 113 {
      return true
    }
    let output = "\(result.standardError)\n\(result.standardOutput)".lowercased()
    return output.contains("no such process")
      || output.contains("could not find specified service")
      || output.contains("service not found")
  }
}
