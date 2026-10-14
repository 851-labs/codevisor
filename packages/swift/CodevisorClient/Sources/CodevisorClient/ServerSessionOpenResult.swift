import CodevisorProtocol
import Foundation

public struct ServerSessionOpenResult: Sendable {
  public var response: ServerSessionOpenResponse
  public var data: Data?

  public init(response: ServerSessionOpenResponse, data: Data?) {
    self.response = response
    self.data = data
  }
}

extension CodevisorServerClienting {
  public func openSessionReturningData(
    _ session: ChatSession,
    project: Project?,
    workspaceId: UUID?,
    transcriptLimit: Int
  ) async throws -> ServerSessionOpenResult? {
    try await openSession(
      session,
      project: project,
      workspaceId: workspaceId,
      transcriptLimit: transcriptLimit
    ).map { ServerSessionOpenResult(response: $0, data: nil) }
  }
}
