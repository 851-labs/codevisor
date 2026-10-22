import ACPKit
import CodevisorProtocol
import Foundation

public struct ProjectCloneProgress: Equatable, Sendable {
  public var stage: String
  public var percent: Double?
  public var completed: Int?
  public var total: Int?
  public var bytes: Int64?
  public var bytesPerSecond: Int64?

  public init(
    stage: String,
    percent: Double? = nil,
    completed: Int? = nil,
    total: Int? = nil,
    bytes: Int64? = nil,
    bytesPerSecond: Int64? = nil
  ) {
    self.stage = stage
    self.percent = percent
    self.completed = completed
    self.total = total
    self.bytes = bytes
    self.bytesPerSecond = bytesPerSecond
  }
}

public enum ProjectSetupEvent: Equatable, Sendable {
  case started
  case log(stream: String, line: String)
  case progress(ProjectCloneProgress)
  case completed(durationMs: Double?)
  case failed(message: String, code: String?, durationMs: Double?)

  public static func from(_ envelope: ServerEventEnvelope, projectId: String) -> ProjectSetupEvent? {
    guard envelope.kind == "project.setup",
      envelope.subjectId.caseInsensitiveCompare(projectId) == .orderedSame,
      let state = envelope.payload["state"]?.stringValue
    else {
      return nil
    }
    switch state {
    case "started":
      return .started
    case "log":
      guard let line = envelope.payload["line"]?.stringValue else { return nil }
      return .log(stream: envelope.payload["stream"]?.stringValue ?? "stdout", line: line)
    case "progress":
      guard let progress = envelope.payload["progress"],
        let stage = progress["stage"]?.stringValue
      else { return nil }
      return .progress(
        ProjectCloneProgress(
          stage: stage,
          percent: progress["percent"]?.doubleValue,
          completed: progress["completed"]?.doubleValue.map { Int($0) },
          total: progress["total"]?.doubleValue.map { Int($0) },
          bytes: progress["bytes"]?.doubleValue.map { Int64($0) },
          bytesPerSecond: progress["bytesPerSecond"]?.doubleValue.map { Int64($0) }
        ))
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

public enum ProjectCloneOutcome: Equatable, Sendable {
  case created
  case failed(message: String, code: String?)

  public static func from(_ envelope: ServerEventEnvelope, projectId: String) -> ProjectCloneOutcome? {
    guard envelope.subjectId.caseInsensitiveCompare(projectId) == .orderedSame else { return nil }
    if envelope.kind == "project.created" { return .created }
    if case let .failed(message, code, _) = ProjectSetupEvent.from(envelope, projectId: projectId) {
      return .failed(message: message, code: code)
    }
    return nil
  }
}
