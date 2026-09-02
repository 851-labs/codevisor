import Foundation

public extension CodevisorServerClienting {
  func transcriptItemDetails(
    id: UUID,
    itemId: String,
    throughRevision: Int?
  ) async throws -> ServerTranscriptItemDetails {
    throw CodevisorServerClientError.httpStatus(404, "")
  }
}
