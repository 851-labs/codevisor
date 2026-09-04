import Foundation

/// Seven completed startup milestones. The final milestone belongs to the
/// client: a listening process is ready only after its health identity matches.
public struct LocalServerStartupProgress: Codable, Equatable, Sendable {
  public struct Work: Codable, Equatable, Sendable {
    public var id: String
    public var completed: Int
    public var total: Int
    public var name: String
  }

  public var version: Int = 1
  public var bootId: String
  public var pid: Int
  public var startedAt: String
  public var updatedAt: String
  public var elapsedMs: Int = 0
  public var stage: String
  public var completed: Int
  public var total: Int = 7
  public var state: String = "starting"
  public var work: Work?
  public var error: String?

  public init(stage: String, completed: Int, bootId: String = "", pid: Int = 0) {
    self.stage = stage
    self.completed = completed
    self.bootId = bootId
    self.pid = pid
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    self.startedAt = formatter.string(from: Date())
    self.updatedAt = startedAt
  }

  public var stageOrder: Int {
    [
      "preparingService", "startingProcess", "loadingRuntime", "acquiringDatabase", "openingDatabase",
      "restoringTerminals", "initializingServices", "checkingHealth", "ready",
    ].firstIndex(of: stage) ?? -1
  }

  public var fractionCompleted: Double {
    Double(min(7, max(0, completed))) / 7
  }

  public var label: String {
    switch stage {
    case "preparingService": "Preparing background service"
    case "startingProcess": "Starting server process"
    case "loadingRuntime": "Loading server runtime"
    case "acquiringDatabase": "Waiting for database access"
    case "openingDatabase": "Preparing database"
    case "restoringTerminals": "Restoring saved terminals"
    case "initializingServices": "Initializing server services"
    case "checkingHealth", "ready": completed == 7 ? "Server ready" : "Checking server connection"
    default: "Starting server"
    }
  }

  /// A repeated write of the same work is not evidence of forward progress.
  public var progressKey: String {
    "\(bootId):\(stage):\(completed):\(work?.id ?? ""):\(work?.completed ?? 0)"
  }

  public func belongsToAttempt(startedAfter: Date, expectedBootId: String?, now: Date = Date()) -> Bool {
    let milestones = [
      "loadingRuntime": 2, "acquiringDatabase": 3, "openingDatabase": 3, "restoringTerminals": 4,
      "initializingServices": 5, "checkingHealth": 6, "ready": 6,
    ]
    guard version == 1, total == 7, milestones[stage] == completed, pid > 0,
      !bootId.isEmpty, expectedBootId == nil || bootId == expectedBootId,
      ["starting", "ready", "failed"].contains(state),
      let start = Self.date(startedAt), let update = Self.date(updatedAt),
      start >= startedAfter.addingTimeInterval(-0.001), start <= now.addingTimeInterval(5),
      update >= start, update <= now.addingTimeInterval(5)
    else { return false }
    if let work, work.completed < 0 || work.total < 0 || work.completed > work.total { return false }
    return true
  }

  private static func date(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
  }
}

public extension LocalServerControlling {
  var startupProgress: LocalServerStartupProgress? { nil }
}
