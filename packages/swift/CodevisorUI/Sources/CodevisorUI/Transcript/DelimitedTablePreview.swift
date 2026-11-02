import Foundation
import MarkdownCore
import TranscriptKit

struct DelimitedTablePreview: Equatable, Sendable {
  static let shownRowLimit = 10
  private static let maximumBytes = 2_000_000

  let headers: [String]
  let rows: [[String]]
  let hiddenRowCount: Int

  init?(data: Data, delimiter: Character) {
    guard data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8), !text.contains("\0"),
      let parsed = DelimitedTextTable.rows(in: text, delimiter: delimiter), let header = parsed.first,
      parsed.dropFirst().allSatisfy({ $0.count <= header.count })
    else { return nil }

    let body = parsed.dropFirst()
    headers = header
    rows = body.prefix(Self.shownRowLimit).map { Self.padded($0, to: header.count) }
    hiddenRowCount = max(0, body.count - Self.shownRowLimit)
  }

  var block: MarkdownBlock {
    .table(
      headers: headers.map { MarkdownText($0) },
      alignments: Array(repeating: .none, count: headers.count),
      rows: rows.map { row in row.map { MarkdownText($0) } }
    )
  }

  var hiddenRowsNote: String? {
    switch hiddenRowCount {
    case 0: nil
    case 1: "1 more row"
    default: "\(hiddenRowCount.formatted()) more rows"
    }
  }

  private static func padded(_ row: [String], to count: Int) -> [String] {
    row + Array(repeating: "", count: count - row.count)
  }
}
