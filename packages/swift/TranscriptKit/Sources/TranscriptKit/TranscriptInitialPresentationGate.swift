/// A one-way readiness gate for the first paint of a virtualized transcript.
///
/// The transcript may lay out invisibly using estimates while history is
/// hydrating. It becomes presentable only when every row in the current
/// initial render window has authoritative geometry. Once opened, it never
/// hides again; subsequent measurement changes use the normal scroll policy.
public struct TranscriptInitialPresentationGate: Sendable, Equatable {
  public private(set) var isReady = false

  public init() {}

  /// Returns `true` only for the update that transitions the gate to ready.
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

  /// Opens the gate for a user-send flight into a transcript that has never
  /// been presented, such as a brand-new chat's first send. The flight has
  /// already established its own readiness (the destination row is laid out
  /// and presentation-ready), and it deliberately holds back the active
  /// projection and the rows beneath it until it lands, so the normal
  /// requirements cannot be met until after the reply arrives. History that
  /// is still hydrating keeps the gate closed: the flight never reveals a
  /// partially restored transcript.
  ///
  /// Returns `true` only for the update that transitions the gate to ready.
  @discardableResult
  public mutating func openForSendPresentation(isHydrating: Bool) -> Bool {
    guard !isReady, !isHydrating else { return false }
    isReady = true
    return true
  }
}
