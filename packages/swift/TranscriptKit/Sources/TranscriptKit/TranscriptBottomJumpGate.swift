import Foundation

public struct TranscriptBottomJumpGate: Sendable, Equatable {
  public private(set) var isActive = false

  public init() {}

  public mutating func begin() {
    isActive = true
  }

  public mutating func cancel() {
    isActive = false
  }

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
