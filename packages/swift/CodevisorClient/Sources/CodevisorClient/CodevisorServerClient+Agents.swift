import Foundation

extension CodevisorServerClienting {
  public func archiveAgent(id: UUID) async throws {
    throw CodevisorServerClientError.httpStatus(405, "Archiving an agent is unavailable on this server.")
  }
}

extension CodevisorServerClient {
  public func archiveAgent(id: UUID) async throws {
    try await sendNoResponse("/v1/agents/\(id.uuidString.lowercased())/archive", method: "POST", body: EmptyBody())
  }
}
