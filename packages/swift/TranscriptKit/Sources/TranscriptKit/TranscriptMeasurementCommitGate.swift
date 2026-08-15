/// Tracks the scroll phase in which transcript measurement commits may safely
/// update document geometry.
///
/// Direct manipulation remains commit-safe: the user's finger supplies the
/// next scroll position after an anchor correction. UIKit deceleration is
/// different. A programmatic `contentOffset` correction replaces its
/// internally owned momentum animation, so measurements wait until momentum
/// ends and then commit as one geometry snapshot.
public struct TranscriptMeasurementCommitGate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case dragging
        case decelerating
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var allowsGeometryCommit: Bool {
        phase != .decelerating
    }

    public mutating func draggingDidBegin() {
        phase = .dragging
    }

    public mutating func draggingDidEnd(willDecelerate: Bool) {
        phase = willDecelerate ? .decelerating : .idle
    }

    public mutating func interactionDidEnd() {
        phase = .idle
    }
}
