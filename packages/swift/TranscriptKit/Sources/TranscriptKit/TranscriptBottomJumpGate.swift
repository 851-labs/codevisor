import Foundation

/// Keeps an explicit scroll-to-bottom command authoritative while the
/// virtualizer replaces estimated destination rows with exact measurements.
///
/// Without this gate, the first measurement correction preserves the newly
/// visible row instead of the requested bottom edge, leaving the viewport
/// above the bottom and making the user press the button again. The intent is
/// released as soon as the mounted destination window is fully resolved, so
/// later disclosure changes retain the transcript's normal anchor behavior.
public struct TranscriptBottomJumpGate: Sendable, Equatable {
  public private(set) var isActive = false

  public init() {}

  public mutating func begin() {
    isActive = true
  }

  public mutating func cancel() {
    isActive = false
  }

  /// Returns true only when this call completes an active jump.
  @discardableResult
  public mutating func resolve(
    requiredKeys: Set<String>,
    resolvedKeys: Set<String>,
    hasPendingMeasurements: Bool
  ) -> Bool {
    guard isActive,
      !requiredKeys.isEmpty,
      !hasPendingMeasurements,
      requiredKeys.isSubset(of: resolvedKeys)
    else { return false }
    isActive = false
    return true
  }
}
