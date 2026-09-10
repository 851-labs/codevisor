#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI

  /// Value inputs for isolated text preparation. The immutable attributed
  /// input is used by syntax highlighting; Markdown is converted on the worker.
  enum PreparedTextContent: @unchecked Sendable {
    case attributed(NSAttributedString)
    case markdown(blocks: [MarkdownBlock], theme: MarkdownTheme, foregroundColor: Color)
    #if canImport(AppKit)
      case table(headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]], theme: MarkdownTheme)
    #endif

    enum Key: Hashable {
      case attributed(NSAttributedString)
      case markdown([MarkdownBlock], theme: Int, foreground: Color)
      case table([MarkdownText], [ColumnAlignment], [[MarkdownText]], theme: Int)
    }

    var key: Key {
      switch self {
      case let .attributed(text): .attributed(text)
      case let .markdown(blocks, theme, foreground):
        .markdown(blocks, theme: theme.renderFingerprint, foreground: foreground)
      #if canImport(AppKit)
        case let .table(headers, alignments, rows, theme):
          .table(headers, alignments, rows, theme: theme.renderFingerprint)
      #endif
      }
    }

    func prepare(width: CGFloat, wrapsText: Bool) throws -> PreparedNativeTextLayout {
      try Task.checkCancellation()
      let text: NSAttributedString
      var layoutWidth = width
      switch self {
      case let .attributed(attributed): text = attributed
      case let .markdown(blocks, theme, foregroundColor):
        text = MarkdownTextRunRenderer.attributedString(for: blocks, theme: theme, foregroundColor: foregroundColor)
      #if canImport(AppKit)
        case let .table(headers, alignments, rows, theme):
          let table = MarkdownTableRenderer.prepare(headers: headers, rows: rows, theme: theme)
          layoutWidth = MarkdownTextTableGeometry.width(
            max(width, MarkdownTableMetrics.minimumTableWidth(columnMinimumWidths: table.columnMinimumWidths)))
          text = MarkdownTableRenderer.make(prepared: table, alignments: alignments, theme: theme, width: layoutWidth)
      #endif
      }
      return try PreparedNativeTextLayout(text: text, width: layoutWidth, wrapsText: wrapsText)
    }

    var attributedText: NSAttributedString? {
      if case let .attributed(text) = self { return text }
      return nil
    }
  }
#endif
