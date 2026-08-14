/// Keeps the identities in a collection stable for the duration of a user
/// interaction while allowing every element's current value to flow through.
///
/// Rows which appear after the interaction begins are placed after the rows
/// the user could already be targeting. Call `incorporate(_:)` after rendering
/// them so later model changes cannot reorder those new rows either.
public struct InteractionDeferredOrder<ID: Hashable & Sendable>: Sendable {
    private var lockedIDs: [ID]?

    public init() {}

    public var isLocked: Bool { lockedIDs != nil }

    /// Starts deferring order changes. Repeated calls intentionally preserve
    /// the first snapshot so overlapping pointer and touch interactions do not
    /// replace the order underneath one another.
    public mutating func lock(to ids: [ID]) {
        guard lockedIDs == nil else { return }
        lockedIDs = unique(ids)
    }

    public mutating func unlock() {
        lockedIDs = nil
    }

    /// Adds identities first seen during the interaction in their currently
    /// rendered order.
    public mutating func incorporate(_ ids: [ID]) {
        guard var lockedIDs else { return }
        var seen = Set(lockedIDs)
        for id in ids where seen.insert(id).inserted {
            lockedIDs.append(id)
        }
        self.lockedIDs = lockedIDs
    }

    /// Returns the latest values in the locked identity order. Missing values
    /// disappear immediately; values not present in the snapshot remain
    /// visible at the end in their input order.
    public func applying<Value>(to values: [Value], id: KeyPath<Value, ID>) -> [Value] {
        guard let lockedIDs else { return values }
        let ranks = Dictionary(uniqueKeysWithValues: lockedIDs.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted { left, right in
            let leftRank = ranks[left.element[keyPath: id]]
            let rightRank = ranks[right.element[keyPath: id]]
            switch (leftRank, rightRank) {
            case let (leftRank?, rightRank?): return leftRank < rightRank
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left.offset < right.offset
            }
        }.map(\.element)
    }

    private func unique(_ ids: [ID]) -> [ID] {
        var seen: Set<ID> = []
        return ids.filter { seen.insert($0).inserted }
    }
}
