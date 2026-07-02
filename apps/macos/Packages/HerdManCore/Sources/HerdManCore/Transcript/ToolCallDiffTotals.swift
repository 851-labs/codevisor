import Foundation
import ACPKit

public extension ToolCall {
    /// Header counter totals for an edit tool call: streamed `diffStats` when
    /// present, else computed from completed diff content, else nil (no
    /// counter shown).
    var diffTotals: LineDiff.Totals? {
        if let diffStats, !diffStats.isEmpty {
            return LineDiff.Totals(
                added: diffStats.map(\.added).reduce(0, +),
                removed: diffStats.map(\.removed).reduce(0, +)
            )
        }
        let diffs = (content ?? []).compactMap { block -> (String?, String)? in
            if case let .diff(_, oldText, newText) = block { return (oldText, newText) }
            return nil
        }
        guard !diffs.isEmpty else { return nil }
        return diffs.reduce(into: LineDiff.Totals(added: 0, removed: 0)) { totals, diff in
            let t = LineDiff.totals(old: diff.0, new: diff.1)
            totals.added += t.added
            totals.removed += t.removed
        }
    }
}
