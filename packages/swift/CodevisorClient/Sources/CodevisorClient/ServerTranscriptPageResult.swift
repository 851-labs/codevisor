import Foundation

public struct ServerTranscriptPageResult: Sendable {
  public var page: ServerTranscriptPage
  public var data: Data?

  public init(page: ServerTranscriptPage, data: Data?) {
    self.page = page
    self.data = data
  }
}

extension CodevisorServerClienting {
  public func transcriptPageReturningData(
    id: UUID, before: String?, limit: Int
  ) async throws -> ServerTranscriptPageResult {
    ServerTranscriptPageResult(page: try await transcriptPage(id: id, before: before, limit: limit), data: nil)
  }
}
