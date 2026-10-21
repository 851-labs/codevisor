import SwiftUI

public enum MarkdownTableNaturalWidth {
  @MainActor
  public static func widest(in blocks: [MarkdownBlock], theme: MarkdownTheme) -> CGFloat {
    blocks.reduce(0) { widest, block in
      guard case let .table(headers, alignments, rows) = block else { return widest }
      return max(widest, ceil(width(headers: headers, alignments: alignments, rows: rows, theme: theme)))
    }
  }

  @MainActor
  private static func width(
    headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]], theme: MarkdownTheme
  ) -> CGFloat {
    #if canImport(AppKit)
      let prepared = MarkdownTableRenderer.prepare(headers: headers, rows: rows, theme: theme)
      return prepared.columnContentWidths.reduce(0, +)
        + MarkdownTableMetrics.horizontalPadding * 2 * CGFloat(prepared.columnCount)
    #elseif canImport(UIKit)
      return UIKitMarkdownTableLayout.naturalWidth(
        headers: headers, alignments: alignments, rows: rows, theme: theme)
    #else
      return 0
    #endif
  }
}
