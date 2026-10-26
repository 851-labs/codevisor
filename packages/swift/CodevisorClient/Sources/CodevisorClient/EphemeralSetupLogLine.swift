import CodevisorProtocol
import Foundation

public struct EphemeralSetupLogLine: Equatable, Sendable {
  public let stage: String
  public let stream: String
  public let line: String

  public init(stage: String, stream: String, line: String) {
    self.stage = stage
    self.stream = stream
    self.line = line
  }

  public static func from(_ envelope: ServerEventEnvelope, machineId: String) -> EphemeralSetupLogLine? {
    guard envelope.kind == "ephemeral.setup",
      envelope.subjectId.caseInsensitiveCompare(machineId) == .orderedSame,
      let stage = envelope.payload["stage"]?.stringValue,
      let line = envelope.payload["line"]?.stringValue
    else {
      return nil
    }
    return EphemeralSetupLogLine(
      stage: stage, stream: envelope.payload["stream"]?.stringValue ?? "stdout", line: line)
  }

  public static func liveLog(
    _ client: any CodevisorServerClienting,
    machineId: String
  ) -> AsyncStream<EphemeralSetupLogLine> {
    let tail = ServerSetupEventTail.follow(client, kinds: ["ephemeral.setup"], subjectId: machineId)
    return AsyncStream { continuation in
      let task = Task {
        for await item in tail {
          switch item {
          case let .event(envelope):
            if let line = from(envelope, machineId: machineId) { continuation.yield(line) }
          case .skipped:
            continuation.yield(
              EphemeralSetupLogLine(stage: "", stream: "stderr", line: ServerSetupEventTail.skippedOutputLine))
          }
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
