public struct TranscriptProjectionPublicationState<Request>: Sendable, Equatable
where Request: Sendable & Equatable {
  public private(set) var publishedRequest: Request?

  public init(publishedRequest: Request? = nil) {
    self.publishedRequest = publishedRequest
  }

  public func isPending(currentRequest: Request) -> Bool {
    publishedRequest != currentRequest
  }

  public mutating func publish(_ request: Request) {
    publishedRequest = request
  }

  public mutating func reset() {
    publishedRequest = nil
  }
}
