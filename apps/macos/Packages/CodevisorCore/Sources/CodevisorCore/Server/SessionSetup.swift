import Foundation
import ACPKit

/// One output line captured while a pre-chat setup step runs (e.g. `git
/// worktree add` and its checkout hooks, streamed as `worktree.setup` events).
public struct SessionSetupLogLine: Identifiable, Equatable, Sendable {
    public let id: Int
    /// "stdout" or "stderr".
    public let stream: String
    public let text: String

    public init(id: Int, stream: String, text: String) {
        self.id = id
        self.stream = stream
        self.text = text
    }
}

/// A step that runs before the chat can start (worktree setup, starting the
/// agent). Rendered like the transcript's "Worked for…" section: a live timer
/// while running, "<completedTitle> in 60s" when done, and expandable log
/// lines / an error when something goes wrong.
public struct SessionSetupPhase: Identifiable, Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case running
        case succeeded
        case failed(String)
    }

    public let id: String
    /// Present-tense title while running, e.g. "Setting up worktree".
    public let activeTitle: String
    /// Past-tense title once done, e.g. "Set up worktree" → "Set up worktree in 60s".
    public let completedTitle: String
    /// Title when the step fails, e.g. "Could not set up worktree".
    public let failedTitle: String
    public let startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var outcome: Outcome
    public private(set) var logs: [SessionSetupLogLine]

    public init(
        id: String,
        activeTitle: String,
        completedTitle: String,
        failedTitle: String,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.activeTitle = activeTitle
        self.completedTitle = completedTitle
        self.failedTitle = failedTitle
        self.startedAt = startedAt
        endedAt = nil
        outcome = .running
        logs = []
    }

    public var isRunning: Bool { outcome == .running }

    public var failureMessage: String? {
        if case let .failed(message) = outcome { return message }
        return nil
    }

    /// Elapsed wall-clock time once the phase has ended; nil while running.
    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    public mutating func appendLog(stream: String, line: String) {
        logs.append(SessionSetupLogLine(id: logs.count, stream: stream, text: line))
    }

    /// Marks success. A server-measured duration (ms) wins over local clocks
    /// so the reported time matches what actually ran.
    public mutating func succeed(durationMs: Double? = nil, at date: Date = Date()) {
        outcome = .succeeded
        endedAt = endDate(durationMs: durationMs, fallback: date)
    }

    public mutating func fail(message: String, durationMs: Double? = nil, at date: Date = Date()) {
        outcome = .failed(message)
        endedAt = endDate(durationMs: durationMs, fallback: date)
    }

    private func endDate(durationMs: Double?, fallback: Date) -> Date {
        guard let durationMs else { return fallback }
        return startedAt.addingTimeInterval(durationMs / 1000)
    }
}

public extension SessionSetupPhase {
    static let worktreePhaseId = "worktree"
    static let agentPhaseId = "agent"

    static func worktree(startedAt: Date = Date()) -> SessionSetupPhase {
        SessionSetupPhase(
            id: worktreePhaseId,
            activeTitle: "Setting up worktree",
            completedTitle: "Set up worktree",
            failedTitle: "Could not set up worktree",
            startedAt: startedAt
        )
    }

    static func startingAgent(named name: String, startedAt: Date = Date()) -> SessionSetupPhase {
        SessionSetupPhase(
            id: agentPhaseId,
            activeTitle: "Starting \(name)",
            completedTitle: "Started \(name)",
            failedTitle: "Could not start \(name)",
            startedAt: startedAt
        )
    }
}

/// A decoded `worktree.setup` event envelope: progress the server publishes
/// while it materializes a worktree (subjectId = the worktree id supplied by
/// the client at creation time).
public enum WorktreeSetupEvent: Equatable, Sendable {
    case started
    case log(stream: String, line: String)
    case completed(durationMs: Double?)
    case failed(message: String, durationMs: Double?)

    public static func from(_ envelope: ServerEventEnvelope, worktreeId: String) -> WorktreeSetupEvent? {
        guard envelope.kind == "worktree.setup",
              envelope.subjectId.caseInsensitiveCompare(worktreeId) == .orderedSame,
              let state = envelope.payload["state"]?.stringValue else {
            return nil
        }
        switch state {
        case "started":
            return .started
        case "log":
            guard let line = envelope.payload["line"]?.stringValue else { return nil }
            return .log(stream: envelope.payload["stream"]?.stringValue ?? "stdout", line: line)
        case "completed":
            return .completed(durationMs: envelope.payload["durationMs"]?.doubleValue)
        case "failed":
            return .failed(
                message: envelope.payload["message"]?.stringValue ?? "Worktree setup failed.",
                durationMs: envelope.payload["durationMs"]?.doubleValue
            )
        default:
            return nil
        }
    }
}

/// A decoded `project.setup` event envelope: progress the server publishes
/// while it clones a git remote into a project (subjectId = the project id
/// supplied by the client with the clone request).
public enum ProjectSetupEvent: Equatable, Sendable {
    case started
    case log(stream: String, line: String)
    case completed(durationMs: Double?)
    case failed(message: String, code: String?, durationMs: Double?)

    public static func from(_ envelope: ServerEventEnvelope, projectId: String) -> ProjectSetupEvent? {
        guard envelope.kind == "project.setup",
              envelope.subjectId.caseInsensitiveCompare(projectId) == .orderedSame,
              let state = envelope.payload["state"]?.stringValue else {
            return nil
        }
        switch state {
        case "started":
            return .started
        case "log":
            guard let line = envelope.payload["line"]?.stringValue else { return nil }
            return .log(stream: envelope.payload["stream"]?.stringValue ?? "stdout", line: line)
        case "completed":
            return .completed(durationMs: envelope.payload["durationMs"]?.doubleValue)
        case "failed":
            return .failed(
                message: envelope.payload["message"]?.stringValue ?? "Clone failed.",
                code: envelope.payload["code"]?.stringValue,
                durationMs: envelope.payload["durationMs"]?.doubleValue
            )
        default:
            return nil
        }
    }
}
