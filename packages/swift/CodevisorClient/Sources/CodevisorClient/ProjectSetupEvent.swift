import ACPKit
import CodevisorProtocol
import Foundation

public enum ProjectSetupEvent: Equatable, Sendable {
  case started
  case log(stream: String, line: String)
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
