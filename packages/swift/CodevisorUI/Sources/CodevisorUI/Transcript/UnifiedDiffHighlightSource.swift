import TranscriptKit

struct UnifiedDiffHighlightSource {
  let old: String?
  let new: String

  init(file: UnifiedDiff.File) {
    let rows = file.maxLineNumber <= Self.maximumLineNumber ? file.rows : []
    old = Self.text(of: rows, at: \.oldLine)
    new = Self.text(of: rows, at: \.newLine) ?? ""
  }

  private static func text(of rows: [LineDiff.Row], at line: KeyPath<LineDiff.Row, Int?>) -> String? {
    let placed = rows.compactMap { row in row[keyPath: line].map { ($0, row.text) } }
    guard let last = placed.map(\.0).max() else { return nil }
    var lines = Array(repeating: "", count: last)
    for (number, text) in placed { lines[number - 1] = text }
    return lines.joined(separator: "\n")
  }

  private static let maximumLineNumber = 20_000
}
