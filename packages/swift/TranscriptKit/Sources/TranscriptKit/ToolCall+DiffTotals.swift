import Foundation
import ACPKit

extension ToolCall {
  public var diffTotals: LineDiff.Totals? {
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

  public var displayTitle: String {
    displayTitle(diffTotals: diffTotals)
  }

  public func displayTitle(diffTotals: LineDiff.Totals?) -> String {
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
