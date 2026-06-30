import Foundation

/// Detects partially-streamed markdown constructs so the renderer can present
/// them gracefully instead of flickering. Ported from the streamdown approach
/// of scanning for unclosed code fences and table delimiters.
public enum IncompleteMarkdown {
    /// Returns the fence character and run length if a line opens or closes a
    /// fenced code block (0–3 leading spaces, then 3+ backticks or tildes).
    static func fenceRun(in line: Substring) -> (character: Character, length: Int)? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " ", spaces < 4 {
            spaces += 1
            index = line.index(after: index)
        }
        if spaces > 3 { return nil }
        guard index < line.endIndex else { return nil }
        let fenceChar = line[index]
        guard fenceChar == "`" || fenceChar == "~" else { return nil }
        var length = 0
        while index < line.endIndex, line[index] == fenceChar {
            length += 1
            index = line.index(after: index)
        }
        return length >= 3 ? (fenceChar, length) : nil
    }

    /// Whether the markdown ends with an unterminated fenced code block.
    public static func hasUnclosedCodeFence(_ markdown: String) -> Bool {
        var openChar: Character?
        var openLength = 0
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (character, length) = fenceRun(in: line) else { continue }
            if openChar == nil {
                openChar = character
                openLength = length
            } else if character == openChar, length >= openLength {
                openChar = nil
                openLength = 0
            }
        }
        return openChar != nil
    }

    /// Whether the last line looks like the header of a table whose delimiter
    /// row has not arrived yet (a table being streamed in).
    public static func hasIncompleteTable(_ markdown: String) -> Bool {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last else { return false }
        // A header line contains a pipe but is not itself a delimiter row, and
        // there is no following delimiter row yet.
        guard last.contains("|"), !isDelimiterRow(last) else { return false }
        return lines.count >= 1
    }

    /// Whether a line is a GFM table delimiter row, e.g. `| --- | :--: |`.
    static func isDelimiterRow(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-") else { return false }
        let allowed = Set("-:|" + " ")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return false }
        // Must contain at least one run of dashes.
        return trimmed.contains("-")
    }
}
