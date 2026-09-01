import CoreGraphics

/// Deduplicates reverse-pagination requests without consuming demand that the
/// pagination owner could not accept.
///
/// Native scroll views detect proximity to the top, while their SwiftUI owner
/// owns request lifetime. The owner must acknowledge that it actually started
/// a request before this policy records the oldest row as handled.
public struct TranscriptHistoryPrefetchPolicy: Sendable {
    private var lastAcceptedOldestKey: String?

    public init() {}

    /// Attempts to start a request when the viewport enters the prefetch zone.
    /// Returns true only when `request` accepts the demand.
    @discardableResult
    public mutating func requestIfNeeded(
        oldestKey: String,
        distanceFromTop: CGFloat,
        threshold: CGFloat,
        force: Bool = false,
        request: () -> Bool
    ) -> Bool {
        if !force, distanceFromTop > threshold {
            if distanceFromTop > threshold * 1.25 {
                lastAcceptedOldestKey = nil
            }
            return false
        }
        guard force || oldestKey != lastAcceptedOldestKey else { return false }
        guard request() else { return false }
        lastAcceptedOldestKey = oldestKey
        return true
    }
}
