import CodevisorProtocol
import Foundation

/// A chat open's decoded response and, when the transport has one, the exact
/// bytes it was decoded from. The bytes are what the on-device transcript
/// cache stores: decoding them again later yields the same response without
/// every transcript type needing an encoder.
public struct ServerSessionOpenResult: Sendable {
  public var response: ServerSessionOpenResponse
  public var data: Data?

  public init(response: ServerSessionOpenResponse, data: Data?) {
    self.response = response
    self.data = data
  }
}

extension CodevisorServerClienting {
  /// Fakes and older transports have no raw body; the chat still opens, it
  /// just isn't cached.
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
