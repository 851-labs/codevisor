import Foundation

public extension CodevisorServerClienting {
  func transcriptItemDetails(
    id: UUID,
    itemId: String,
    after: String?
  ) async throws -> ServerTranscriptItemDetails {
    throw CodevisorServerClientError.httpStatus(404, "")
  }
  func transcriptBodyPage(
    id: UUID, itemId: String, key: String, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    throw CodevisorServerClientError.invalidResponse
  }
}
