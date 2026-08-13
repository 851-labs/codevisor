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
        requiredKeys: Set<String>,
        resolvedKeys: Set<String>,
    ) -> Bool {
        guard !isReady,
              !isHydrating,
              requiredKeys.isSubset(of: resolvedKeys) else { return false }
        isReady = true
        return true
    }
}
