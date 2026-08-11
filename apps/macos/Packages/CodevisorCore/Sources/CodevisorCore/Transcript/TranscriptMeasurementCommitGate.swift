/// Keeps asynchronous virtual-row measurements from changing scroll geometry
/// while a native touch gesture owns the viewport. Dragging and deceleration
/// are one interaction: queued geometry becomes committable only after both
/// have ended.
public struct TranscriptMeasurementCommitGate: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        case dragging
        case decelerating
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public var allowsGeometryCommit: Bool { phase == .idle }

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
