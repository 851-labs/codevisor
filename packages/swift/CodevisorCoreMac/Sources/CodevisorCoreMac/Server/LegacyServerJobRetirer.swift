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

/// Removes updater-era launchd jobs before the current SMAppService takes
/// ownership. Those jobs used KeepAlive, so merely shutting down their server
/// process lets launchd immediately reclaim the port.
public struct LegacyServerJobRetirer: Sendable {
    public static let labels = [
        "com.851labs.codevisor-recovery",
        "com.851labs.herdman-recovery",
        "com.851labs.HerdMan-recovery",
    ]

    private let runner: any CommandRunner
    private let userID: UInt32
    private let commandTimeout: Duration

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        userID: UInt32 = getuid(),
        commandTimeout: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.userID = userID
        self.commandTimeout = commandTimeout
    }

    /// Idempotent: booting out a loaded job and finding no job are both the
    /// success path. `bootout` is the modern, domain-scoped replacement for
    /// legacy `launchctl remove`, which returns before a job has stopped.
    public func retire() async throws {
        for label in Self.labels {
            let target = "gui/\(userID)/\(label)"
            Log.server.log("Retiring obsolete server job \(target, privacy: .public)")
            let result = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", target],
                environment: nil,
                timeout: commandTimeout
            )
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
