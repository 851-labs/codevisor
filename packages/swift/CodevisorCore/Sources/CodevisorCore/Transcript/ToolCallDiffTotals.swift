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

public extension ToolCall {
    /// The row title, papering over adapters that report a bare tool name
    /// ("Edit") while an edit is running: without a filename or any diff data
    /// there is nothing informative to show, so use a generic progress title.
    /// Adapters that title properly (spaces ⇒ a real phrase) pass through,
    /// and the finished update's title always wins.
    var displayTitle: String {
        displayTitle(diffTotals: diffTotals)
    }

    /// `displayTitle` taking precomputed totals, so callers that already
    /// memoized `diffTotals` (a full Myers diff in the content fallback path)
    /// don't run the diff a second time per render.
    func displayTitle(diffTotals: LineDiff.Totals?) -> String {
        if let integrationTitle = integrationDisplayTitle() {
            return integrationTitle
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard kind == .edit, !isSettled, diffTotals == nil else {
            return trimmed.isEmpty ? "Working…" : trimmed
        }
        let isBareName = trimmed.isEmpty || !trimmed.contains(" ")
        return isBareName ? "Editing file…" : trimmed
    }
}
