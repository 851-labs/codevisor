/// Tracks which asynchronous transcript projection has actually committed.
///
/// The current request can advance before its rows arrive. In particular, an
/// existing chat first commits an empty/loading projection and then advances
/// to its history-backed projection. Readiness must follow that request
/// identity or the initial presentation gate can open over obsolete rows.
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
