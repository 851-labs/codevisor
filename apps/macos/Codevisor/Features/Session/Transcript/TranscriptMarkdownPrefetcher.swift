import AppKit
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import TranscriptKit

@MainActor
final class TranscriptMarkdownPrefetcher {
  static let rowMargin = 30

  private var preparedRows: Set<String> = []
  private var rowWidth: CGFloat = -1
  private var lastWindow: Range<Int>?

  func prefetch(
    _ rows: ArraySlice<TranscriptVirtualRow>,
    rowWidth: CGFloat,
    style: TranscriptMarkdownRowStyle,
    scale: CGFloat,
    appearance: NSAppearance.Name
  ) {
    let isSameWindow = rows.indices == lastWindow && abs(rowWidth - self.rowWidth) <= 0.25
    guard !isSameWindow else { return }
    lastWindow = rows.indices
    forgetPreparedRowsIfWidthChanged(rowWidth)
    for row in rows {
      guard let chunk = Self.settledNativeChunk(row), preparedRows.insert(Self.identity(of: row)).inserted else {
        continue
      }
      let width = TranscriptMarkdownRowHost.contentGeometry(for: chunk, style: style, rowWidth: rowWidth)
        .contentFrame.width
      SettledMarkdownView.prefetch(
        blocks: chunk.blocks, theme: style.markdown, streamID: row.layoutKey,
        width: width, scale: scale, appearance: appearance)
    }
  }

  static func window(around indices: [Int], rowCount: Int) -> Range<Int>? {
    guard let lower = indices.min(), let upper = indices.max(), rowCount > 0 else { return nil }
    return max(0, lower - rowMargin)..<min(rowCount, upper + rowMargin + 1)
  }

  private func forgetPreparedRowsIfWidthChanged(_ width: CGFloat) {
    guard abs(width - rowWidth) > 0.25 else { return }
    rowWidth = width
    preparedRows.removeAll()
  }

  private static func settledNativeChunk(_ row: TranscriptVirtualRow) -> TranscriptMarkdownChunk? {
    guard case let .markdownChunk(chunk) = row.content, chunk.lifecycle == .settled,
      !MarkdownLayoutPolicy.requiresBackgroundTextLayout(chunk.blocks)
    else { return nil }
    return chunk
  }

  private static func identity(of row: TranscriptVirtualRow) -> String {
    "\(row.layoutKey)#\(row.measurementRevision)"
  }
}
