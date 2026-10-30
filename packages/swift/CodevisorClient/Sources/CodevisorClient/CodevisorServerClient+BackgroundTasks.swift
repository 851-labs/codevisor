import Foundation

public struct ServerBackgroundTaskOutput: Sendable, Equatable, Decodable {
  public var lines: [String]

  public init(lines: [String]) {
    self.lines = lines
  }
}

extension CodevisorServerClient {
  public func backgroundTaskOutput(sessionId: UUID, taskId: String) async throws -> ServerBackgroundTaskOutput {
    try await get("/v1/sessions/\(sessionId.uuidString)/tasks/\(Self.taskPathComponent(taskId))/output")
  }

  public func stopBackgroundTask(sessionId: UUID, taskId: String) async throws {
    try await sendNoResponse(
      "/v1/sessions/\(sessionId.uuidString)/tasks/\(Self.taskPathComponent(taskId))/stop", method: "POST")
  }

  private static func taskPathComponent(_ taskId: String) -> String {
    taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? taskId
  }
}
