/// Tracks the scroll phase in which transcript measurement commits may safely
/// update document geometry.
///
/// Direct manipulation remains commit-safe: the user's finger supplies the
/// next scroll position after an anchor correction. UIKit deceleration is
/// different. A programmatic `contentOffset` correction replaces its
/// internally owned momentum animation. Heights at or below the first visible
/// row can still commit without moving the viewport. Changes above it wait
/// until momentum ends, when the reading anchor can be adjusted safely.
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

  public func allowsHeightCommit(rowIndex: Int, firstVisibleRowIndex: Int?) -> Bool {
    if allowsGeometryCommit { return true }
    guard let firstVisibleRowIndex else { return false }
    return rowIndex >= firstVisibleRowIndex
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
