import Foundation

/// Pure text-transformation rules behind the scratchpad's list behavior.
///
/// SwiftUI's rich `TextEditor` has no built-in list support, so bullets are
/// literal leading characters (`• `) managed by these rules: the view
/// intercepts Return to continue lists, watches edits for `- ` / `* `
/// autoformat shortcuts, and exposes a menu command for toggling. Positions
/// are grapheme-cluster (Character) offsets — the view layer converts
/// to/from `AttributedString` indices — which keeps the rules free of
/// SwiftUI types and directly unit-testable.
public enum ScratchpadTextRules {
    /// The result of a rule: the new text plus the collapsed caret position
    /// (character offset) the editor should move the insertion point to.
    public struct Transform: Equatable {
        public var text: AttributedString
        public var caretOffset: Int

        public init(text: AttributedString, caretOffset: Int) {
            self.text = text
            self.caretOffset = caretOffset
        }
    }

    public static let bulletMarker: Character = "•"
    /// Marker plus its trailing space.
    private static let prefixLength = 2

    // MARK: - Return key

    /// Handles Return inside a bulleted list: continues the list with a new
    /// `• ` prefix, or exits the list when the current item is empty.
    /// Returns nil when the caret's paragraph is not a list item (or the
    /// caret sits inside the prefix), letting the editor insert a plain
    /// newline.
    public static func continueListOnReturn(text: AttributedString, caretOffset: Int) -> Transform? {
        let chars = Array(text.characters)
        guard caretOffset >= 0, caretOffset <= chars.count else { return nil }
        let line = paragraphBounds(containing: caretOffset, in: chars)
        guard isBulleted(lineStartingAt: line.start, in: chars) else { return nil }
        let contentStart = line.start + prefixLength
        // Return on an empty item removes the prefix — the way out of a list.
        if line.end == contentStart, caretOffset == line.end {
            var newText = text
            newText.removeSubrange(range(line.start ..< contentStart, in: newText))
            return Transform(text: newText, caretOffset: line.start)
        }
        guard caretOffset >= contentStart else { return nil }
        var newText = text
        newText.insert(AttributedString("\n\(bulletMarker) "), at: index(at: caretOffset, in: newText))
        return Transform(text: newText, caretOffset: caretOffset + 1 + prefixLength)
    }

    // MARK: - Typed shortcuts

    /// Converts markdown-style shortcuts typed at the start of a line:
    /// `- ` / `* ` become a bullet. Call after an edit with the caret
    /// position; returns nil when the text before the caret isn't exactly a
    /// just-typed shortcut.
    public static func applyAutoformat(text: AttributedString, caretOffset: Int) -> Transform? {
        let chars = Array(text.characters)
        guard caretOffset > 0, caretOffset <= chars.count else { return nil }
        let line = paragraphBounds(containing: caretOffset, in: chars)
        switch String(chars[line.start ..< caretOffset]) {
        case "- ", "* ":
            var newText = text
            newText.replaceSubrange(
                range(line.start ..< caretOffset, in: newText),
                with: AttributedString("\(bulletMarker) ")
            )
            return Transform(text: newText, caretOffset: line.start + prefixLength)
        default:
            return nil
        }
    }

    // MARK: - Menu commands

    /// Toggles bullets on every paragraph the selection touches: removes the
    /// bullets if all lines are already bulleted, otherwise bullets every
    /// line.
    public static func toggleBullet(text: AttributedString, selection: Range<Int>) -> Transform {
        let chars = Array(text.characters)
        let lines = paragraphs(intersecting: selection, in: chars)
        let allBulleted = lines.allSatisfy { isBulleted(lineStartingAt: $0.start, in: chars) }

        var newText = text
        var totalDelta = 0
        // Edits run back-to-front so earlier offsets stay valid.
        for line in lines.reversed() {
            let bulleted = isBulleted(lineStartingAt: line.start, in: chars)
            if allBulleted {
                newText.removeSubrange(range(line.start ..< line.start + prefixLength, in: newText))
                totalDelta -= prefixLength
            } else if !bulleted {
                newText.insert(AttributedString("\(bulletMarker) "), at: index(at: line.start, in: newText))
                totalDelta += prefixLength
            }
        }
        let lastEnd = lines.last.map(\.end) ?? 0
        return Transform(text: newText, caretOffset: lastEnd + totalDelta)
    }

    // MARK: - Helpers

    private static func isBulleted(lineStartingAt start: Int, in chars: [Character]) -> Bool {
        start + 1 < chars.count && chars[start] == bulletMarker && chars[start + 1] == " "
    }

    private static func paragraphBounds(containing offset: Int, in chars: [Character]) -> (start: Int, end: Int) {
        var start = min(offset, chars.count)
        while start > 0, chars[start - 1] != "\n" { start -= 1 }
        var end = min(offset, chars.count)
        while end < chars.count, chars[end] != "\n" { end += 1 }
        return (start, end)
    }

    private static func paragraphs(
        intersecting selection: Range<Int>,
        in chars: [Character]
    ) -> [(start: Int, end: Int)] {
        let limit = min(selection.upperBound, chars.count)
        var lines: [(start: Int, end: Int)] = []
        var cursor = paragraphBounds(containing: min(selection.lowerBound, chars.count), in: chars).start
        repeat {
            let line = paragraphBounds(containing: cursor, in: chars)
            lines.append(line)
            cursor = line.end + 1
        } while cursor <= limit
        return lines
    }

    private static func index(at offset: Int, in text: AttributedString) -> AttributedString.Index {
        text.characters.index(text.startIndex, offsetBy: offset)
    }

    private static func range(_ offsets: Range<Int>, in text: AttributedString) -> Range<AttributedString.Index> {
        let start = index(at: offsets.lowerBound, in: text)
        let end = text.characters.index(start, offsetBy: offsets.count)
        return start ..< end
    }
}
