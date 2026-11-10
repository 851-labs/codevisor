import Foundation

public struct ServerRemoteExecTask: Decodable, Equatable, Sendable, Identifiable {
  public let taskId: String
  public let sessionId: String
  public let machine: ServerWorkspaceSync.Machine
  public let description: String
  public let command: String
  public let startedAt: String
  public let outputPath: String

  public var id: String { taskId }
  public var startDate: Date? { try? ServerDateCoding.date(from: startedAt) }
}
