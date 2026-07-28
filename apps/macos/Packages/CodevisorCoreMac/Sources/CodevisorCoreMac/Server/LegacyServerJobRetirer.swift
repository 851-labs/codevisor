import Darwin
import Foundation

public enum LegacyServerJobRetirementError: LocalizedError, Equatable {
    case jobStillLoaded(String)

    public var errorDescription: String? {
        switch self {
        case let .jobStillLoaded(label):
            "The obsolete Codevisor server job \(label) could not be stopped."
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
        "com.851labs.HerdMan-recovery"
    ]

    private let runner: any CommandRunner
    private let userID: UInt32

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        userID: UInt32 = getuid()
    ) {
        self.runner = runner
        self.userID = userID
    }

    /// Idempotent: `launchctl remove` and a missing subsequent `print` are the
    /// success path both when a job was removed and when it never existed.
    public func retire() async throws {
        for label in Self.labels {
            _ = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["remove", label],
                environment: nil
            )
            let inspection = try await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", "gui/\(userID)/\(label)"],
                environment: nil
            )
            if inspection.exitCode == 0 {
                throw LegacyServerJobRetirementError.jobStillLoaded(label)
            }
        }
    }
}
