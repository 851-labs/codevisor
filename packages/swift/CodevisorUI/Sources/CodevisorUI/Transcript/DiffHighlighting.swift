import CodeHighlighter
import Foundation
import TranscriptKit

/// Syntax colors for diff rows, shared by transcript edit cards and the
/// Review pane. Each side is highlighted as a whole document (so multi-line
/// constructs color correctly) and mapped onto rows by line number.
@MainActor
enum DiffHighlighting {
  static func highlights(
    rows: [LineDiff.Row],
    old: String?,
    new: String,
    path: String,
    theme: CodeHighlightTheme?
  ) async -> [Int: AttributedString] {
    guard let theme, let language = CodeHighlighter.language(forPath: path) else { return [:] }

    let newTokens: [[CodeHighlighter.Token]]? =
      rows.contains(where: { $0.newLine != nil })
      ? await CodeHighlighter.shared.highlight(
        code: new, language: language, themeKey: theme.key, themeJSON: theme.json)
      : nil
    var oldTokens: [[CodeHighlighter.Token]]?
    if let old, rows.contains(where: { $0.kind == .removed }) {
      oldTokens = await CodeHighlighter.shared.highlight(
        code: old, language: language, themeKey: theme.key, themeJSON: theme.json)
    }
    guard !Task.isCancelled else { return [:] }

    // Added/context rows read from the new text's token lines, removed
    // rows from the old text's — both 1-based like LineDiff.Row.
    var result: [Int: AttributedString] = [:]
    for row in rows {
      let line: [CodeHighlighter.Token]?
      if let newLine = row.newLine {
        line = newTokens.flatMap { $0.indices.contains(newLine - 1) ? $0[newLine - 1] : nil }
      } else if let oldLine = row.oldLine {
        line = oldTokens.flatMap { $0.indices.contains(oldLine - 1) ? $0[oldLine - 1] : nil }
      } else {
        line = nil
      }
      if let line, !line.isEmpty {
        result[row.id] = attributedLine(line)
      }
    }
    return result
  }
}
