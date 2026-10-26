import Foundation
import ACPKit

public struct SessionSetupLogLine: Identifiable, Equatable, Sendable {
  public let id: Int
  public let stream: String
  public let text: String

  public init(id: Int, stream: String, text: String) {
    self.id = id
    self.stream = stream
    self.text = text
  }
}

public struct SessionSetupPhase: Identifiable, Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed(String)
  }

  public let id: String
  public let activeTitle: String
  public let completedTitle: String
  public let failedTitle: String
  public let upcomingTitle: String
  public private(set) var startedAt: Date
  public private(set) var endedAt: Date?
  public private(set) var outcome: Outcome
  public private(set) var logs: [SessionSetupLogLine]
  public var logResource: ToolDetailResource? = nil
  private var nextLogId = 0

  public init(
    id: String,
    activeTitle: String,
    completedTitle: String,
    failedTitle: String,
    upcomingTitle: String? = nil,
    startedAt: Date = Date(),
    isPending: Bool = false
  ) {
    self.id = id
    self.activeTitle = activeTitle
    self.completedTitle = completedTitle
    self.failedTitle = failedTitle
    self.upcomingTitle = upcomingTitle ?? activeTitle
    self.startedAt = startedAt
    endedAt = nil
    outcome = isPending ? .pending : .running
    logs = []
  }

  public var isPending: Bool { outcome == .pending }
  public var isRunning: Bool { outcome == .running }
  public var isSucceeded: Bool { outcome == .succeeded }

  public var failureMessage: String? {
    if case let .failed(message) = outcome { return message }
    return nil
  }

  public var duration: TimeInterval? {
    endedAt.map { $0.timeIntervalSince(startedAt) }
  }

  public mutating func start(at date: Date = Date()) {
    guard outcome == .pending else { return }
    startedAt = date
    outcome = .running
  }

  public mutating func appendLog(stream: String, line: String) {
    logs.append(SessionSetupLogLine(id: nextLogId, stream: stream, text: String(line.prefix(8192))))
    nextLogId += 1
    if logs.count > 256 { logs.removeFirst(logs.count - 256) }
  }

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

extension SessionSetupPhase {
  public static let worktreePhaseId = "worktree"

  public static func worktree(startedAt: Date = Date()) -> SessionSetupPhase {
    SessionSetupPhase(
      id: worktreePhaseId,
      activeTitle: "Setting up worktree",
      completedTitle: "Set up worktree",
      failedTitle: "Could not set up worktree",
      startedAt: startedAt
    )
  }
}
