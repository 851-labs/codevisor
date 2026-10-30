public struct TranscriptProjectionPublicationState: Sendable, Equatable {
  public private(set) var publishedRequest: TranscriptProjectionRequest?

  public init(publishedRequest: TranscriptProjectionRequest? = nil) {
    self.publishedRequest = publishedRequest
  }

  public func isPending(currentRequest: TranscriptProjectionRequest) -> Bool {
    guard let publishedRequest else { return true }
    return !publishedRequest.standsIn(for: currentRequest)
  }

  public mutating func publish(_ request: TranscriptProjectionRequest) {
    publishedRequest = request
  }

  public mutating func reset() {
    publishedRequest = nil
  }
}
