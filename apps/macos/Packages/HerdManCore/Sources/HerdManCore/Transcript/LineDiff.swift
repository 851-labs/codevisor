import Foundation

/// A line-based diff (Myers, via `CollectionDifference`) rendered in git hunk
/// order: removals appear immediately before the additions that replaced them,
/// with 1-based line numbers for both sides.
public enum LineDiff {
    public struct Row: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable {
            case context, added, removed
        }

        /// Ordinal within one computation — stable for SwiftUI identity.
        public let id: Int
        public let kind: Kind
        /// 1-based line number in the old text; nil for added rows.
        public let oldLine: Int?
        /// 1-based line number in the new text; nil for removed rows.
        public let newLine: Int?
        public let text: String
    }

    public struct Totals: Sendable, Equatable {
        public var added: Int
        public var removed: Int

        public init(added: Int, removed: Int) {
            self.added = added
            self.removed = removed
        }
    }

    public static func rows(old: String?, new: String) -> [Row] {
        let oldLines = lines(of: old ?? "")
        let newLines = lines(of: new)
        // Move inference is deliberately skipped: the UI presents pure
        // adds/removes, and inferred moves would hide changed duplicates.
        let difference = newLines.difference(from: oldLines)
        var removalOffsets = Set<Int>()
        var insertionOffsets = Set<Int>()
        for change in difference {
            switch change {
            case let .remove(offset, _, _): removalOffsets.insert(offset)
            case let .insert(offset, _, _): insertionOffsets.insert(offset)
            }
        }

        var rows: [Row] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            // Emit the current hunk's removals first, then its additions —
            // matching git's presentation of a replacement.
            while oldIndex < oldLines.count, removalOffsets.contains(oldIndex) {
                rows.append(Row(id: rows.count, kind: .removed, oldLine: oldIndex + 1, newLine: nil, text: oldLines[oldIndex]))
                oldIndex += 1
            }
            while newIndex < newLines.count, insertionOffsets.contains(newIndex) {
                rows.append(Row(id: rows.count, kind: .added, oldLine: nil, newLine: newIndex + 1, text: newLines[newIndex]))
                newIndex += 1
            }
            if oldIndex < oldLines.count, newIndex < newLines.count,
               !removalOffsets.contains(oldIndex), !insertionOffsets.contains(newIndex) {
                rows.append(Row(id: rows.count, kind: .context, oldLine: oldIndex + 1, newLine: newIndex + 1, text: newLines[newIndex]))
                oldIndex += 1
                newIndex += 1
            }
        }
        return rows
    }

    public static func totals(old: String?, new: String) -> Totals {
        let difference = lines(of: new).difference(from: lines(of: old ?? ""))
        return Totals(added: difference.insertions.count, removed: difference.removals.count)
    }

    private static func lines(of text: String) -> [String] {
        if text.isEmpty { return [] }
        var lines = text.components(separatedBy: "\n")
        // A trailing newline does not open a final empty line.
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
