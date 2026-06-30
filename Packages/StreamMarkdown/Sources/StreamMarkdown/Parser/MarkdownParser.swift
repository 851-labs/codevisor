import Foundation

/// Parses markdown into an array of top-level `MarkdownBlock`s.
///
/// The parser is line-oriented and streaming-tolerant: an unterminated fenced
/// code block is emitted with `isComplete == false` rather than dropped, so a
/// response can render while it is still arriving.
public struct MarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]

            if let fence = fenceInfo(line) {
                let (block, next) = parseCodeBlock(lines, start: index, fence: fence)
                blocks.append(block)
                index = next
            } else if isBlank(line) {
                index += 1
            } else if let heading = parseHeading(line) {
                blocks.append(heading)
                index += 1
            } else if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
            } else if isBlockQuote(line) {
                let (block, next) = parseBlockQuote(lines, start: index)
                blocks.append(block)
                index = next
            } else if isTableStart(lines, index) {
                let (block, next) = parseTable(lines, start: index)
                blocks.append(block)
                index = next
            } else if bulletContent(line) != nil {
                let (block, next) = parseBulletList(lines, start: index)
                blocks.append(block)
                index = next
            } else if orderedContent(line) != nil {
                let (block, next) = parseOrderedList(lines, start: index)
                blocks.append(block)
                index = next
            } else {
                let (block, next) = parseParagraph(lines, start: index)
                blocks.append(block)
                index = next
            }
        }
        return blocks
    }

    // MARK: - Block detection helpers

    private func leadingSpaces(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else { break }
            if count > 3 { break }
        }
        return count
    }

    func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func fenceInfo(_ line: String) -> (character: Character, length: Int, language: String?)? {
        guard let run = IncompleteMarkdown.fenceRun(in: Substring(line)) else { return nil }
        let trimmed = line.drop(while: { $0 == " " })
        let info = trimmed.dropFirst(run.length).trimmingCharacters(in: .whitespaces)
        return (run.character, run.length, info.isEmpty ? nil : info)
    }

    func parseHeading(_ line: String) -> MarkdownBlock? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let stripped = line.drop(while: { $0 == " " })
        var level = 0
        for character in stripped {
            if character == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6 else { return nil }
        let rest = stripped.dropFirst(level)
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    func isThematicBreak(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        for marker in ["-", "*", "_"] {
            let stripped = trimmed.replacingOccurrences(of: " ", with: "")
            if !stripped.isEmpty, stripped.allSatisfy({ String($0) == marker }) {
                return true
            }
        }
        return false
    }

    func isBlockQuote(_ line: String) -> Bool {
        guard leadingSpaces(line) <= 3 else { return false }
        return line.drop(while: { $0 == " " }).first == ">"
    }

    func bulletContent(_ line: String) -> String? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let stripped = line.drop(while: { $0 == " " })
        guard let marker = stripped.first, "-*+".contains(marker) else { return nil }
        let rest = stripped.dropFirst()
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    func orderedContent(_ line: String) -> (number: Int, text: String)? {
        guard leadingSpaces(line) <= 3 else { return nil }
        let stripped = line.drop(while: { $0 == " " })
        var digits = ""
        var remainder = Substring(stripped)
        for character in stripped {
            if character.isNumber { digits.append(character); remainder = remainder.dropFirst() } else { break }
        }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard let delimiter = remainder.first, delimiter == "." || delimiter == ")" else { return nil }
        let rest = remainder.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, String(rest.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Block parsers

    private func parseCodeBlock(
        _ lines: [String],
        start: Int,
        fence: (character: Character, length: Int, language: String?)
    ) -> (MarkdownBlock, Int) {
        var index = start + 1
        var codeLines: [String] = []
        var isComplete = false
        while index < lines.count {
            if let run = IncompleteMarkdown.fenceRun(in: Substring(lines[index])),
               run.character == fence.character, run.length >= fence.length,
               fenceInfo(lines[index])?.language == nil {
                isComplete = true
                index += 1
                break
            }
            codeLines.append(lines[index])
            index += 1
        }
        return (.codeBlock(language: fence.language, code: codeLines.joined(separator: "\n"), isComplete: isComplete), index)
    }

    private func parseBlockQuote(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var quoted: [String] = []
        while index < lines.count, isBlockQuote(lines[index]) {
            let stripped = lines[index].drop(while: { $0 == " " }).dropFirst() // drop '>'
            let content = stripped.first == " " ? String(stripped.dropFirst()) : String(stripped)
            quoted.append(content)
            index += 1
        }
        let inner = MarkdownParser().parse(quoted.joined(separator: "\n"))
        return (.blockQuote(inner), index)
    }

    private func parseBulletList(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var items: [String] = []
        while index < lines.count, let content = bulletContent(lines[index]) {
            items.append(content)
            index += 1
        }
        return (.bulletList(items), index)
    }

    private func parseOrderedList(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var items: [OrderedListItem] = []
        while index < lines.count, let content = orderedContent(lines[index]) {
            items.append(OrderedListItem(number: content.number, text: content.text))
            index += 1
        }
        return (.orderedList(items), index)
    }

    func isTableStart(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        return lines[index].contains("|") && IncompleteMarkdown.isDelimiterRow(Substring(lines[index + 1]))
    }

    private func parseTable(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        let headers = splitRow(lines[start])
        let alignments = parseAlignments(lines[start + 1], columnCount: headers.count)
        var index = start + 2
        var rows: [[String]] = []
        while index < lines.count, lines[index].contains("|"), !isBlank(lines[index]) {
            rows.append(normalize(splitRow(lines[index]), to: headers.count))
            index += 1
        }
        return (.table(headers: headers, alignments: alignments, rows: rows), index)
    }

    private func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func normalize(_ row: [String], to count: Int) -> [String] {
        var row = row
        while row.count < count { row.append("") }
        if row.count > count { row = Array(row.prefix(count)) }
        return row
    }

    private func parseAlignments(_ line: String, columnCount: Int) -> [ColumnAlignment] {
        let cells = splitRow(line)
        var alignments = cells.map { cell -> ColumnAlignment in
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            switch (left, right) {
            case (true, true): return .center
            case (true, false): return .leading
            case (false, true): return .trailing
            default: return .none
            }
        }
        while alignments.count < columnCount { alignments.append(.none) }
        return Array(alignments.prefix(columnCount))
    }

    private func parseParagraph(_ lines: [String], start: Int) -> (MarkdownBlock, Int) {
        var index = start
        var paragraph: [String] = []
        while index < lines.count {
            let line = lines[index]
            if isBlank(line) || fenceInfo(line) != nil || parseHeading(line) != nil
                || isThematicBreak(line) || isBlockQuote(line)
                || bulletContent(line) != nil || orderedContent(line) != nil
                || isTableStart(lines, index) {
                if index > start { break }
            }
            paragraph.append(line)
            index += 1
            if index < lines.count, isBlank(lines[index]) { break }
        }
        return (.paragraph(paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)), index)
    }
}
