public struct TranscriptInitialPresentationGate: Sendable, Equatable {
  public private(set) var isReady = false

  public init() {}

  @discardableResult
  public mutating func resolve(
    isHydrating: Bool,
    isActiveProjectionPending: Bool = false,
    requiredKeys: Set<String>,
    resolvedKeys: Set<String>,
    hasPendingMeasurements: Bool = false,
  ) -> Bool {
    guard !isReady,
      !isHydrating,
      !isActiveProjectionPending,
      !hasPendingMeasurements,
      requiredKeys.isSubset(of: resolvedKeys)
    else { return false }
    isReady = true
    return true
  }

  @discardableResult
  public mutating func openForSendPresentation(isHydrating: Bool) -> Bool {
    guard !isReady, !isHydrating else { return false }
    isReady = true
    return true
  }
}
