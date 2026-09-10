#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import UIKit

  /// Prepare scalar geometry without constructing thousands of SwiftUI cell
  /// trees. Repeated cell values share their attributed text and measurements.
  // The worker owns all mutable builders. Only immutable attributed strings
  // and numeric geometry cross back to the UI actor; no text views or shared
  // layout managers are created here.
  final class UIKitMarkdownTableLayout: @unchecked Sendable {
    struct CellKey: Hashable {
      let text: MarkdownText
      let isHeader: Bool
      let alignment: ColumnAlignment
    }

    private struct PreparedCell {
      let text: NSAttributedString
      let naturalWidth: CGFloat
      let minimumWidth: CGFloat
    }

    let cells: [[NSAttributedString]]
    let geometry: MarkdownTableGeometry

    init(
      headers: [MarkdownText], alignments: [ColumnAlignment], rows: [[MarkdownText]],
      theme: MarkdownTheme, width: CGFloat
    ) throws {
      let count = max(headers.count, rows.map(\.count).max() ?? 0)
      let padding = MarkdownTableMetrics.horizontalPadding * 2
      var preparedCells: [CellKey: PreparedCell] = [:]
      var natural = [CGFloat](repeating: 1, count: count)
      var minimum = natural
      var keys: [[CellKey]] = []
      var cells: [[NSAttributedString]] = []
      for (row, values) in ([headers] + rows).enumerated() {
        try Task.checkCancellation()
        var rowKeys: [CellKey] = []
        var rowCells: [NSAttributedString] = []
        for column in 0..<count {
          try Task.checkCancellation()
          let key = CellKey(
            text: column < values.count ? values[column] : "",
            isHeader: row == 0,
            alignment: column < alignments.count ? alignments[column] : .none
          )
          let cell: PreparedCell
          if let cached = preparedCells[key] {
            cell = cached
          } else {
            let text = Self.attributedText(key, theme: theme)
            cell = PreparedCell(
              text: text, naturalWidth: max(1, ceil(text.size().width)), minimumWidth: Self.minimumWidth(text)
            )
            preparedCells[key] = cell
          }
          rowKeys.append(key)
          rowCells.append(cell.text)
          natural[column] = max(natural[column], cell.naturalWidth)
          minimum[column] = max(minimum[column], cell.minimumWidth)
        }
        keys.append(rowKeys)
        cells.append(rowCells)
      }
      let widths = MarkdownTableMetrics.distribute(
        contentWidths: natural, minimumWidths: minimum, toFit: width,
        compressesBelowMinimums: false
      ).map { $0 + padding }
      var heightsByWidth: [CGFloat: [CellKey: CGFloat]] = [:]
      var heights: [CGFloat] = []
      let minimumHeight = UIFont.preferredFont(forTextStyle: .body).lineHeight
      for (row, rowKeys) in keys.enumerated() {
        try Task.checkCancellation()
        var height: CGFloat = 1
        for (column, key) in rowKeys.enumerated() {
          let contentWidth = max(1, widths[column] - padding)
          let measured: CGFloat
          if let cached = heightsByWidth[contentWidth]?[key] {
            measured = cached
          } else {
            measured = max(
              minimumHeight,
              ceil(
                cells[row][column].boundingRect(
                  with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
                ).height)
            )
            heightsByWidth[contentWidth, default: [:]][key] = measured
          }
          height = max(height, measured + MarkdownTableMetrics.verticalPadding * 2)
        }
        heights.append(ceil(height))
      }
      self.cells = cells
      geometry = MarkdownTableGeometry(columnWidths: widths, rowHeights: heights)
    }

    private static func attributedText(_ key: CellKey, theme: MarkdownTheme) -> NSAttributedString {
      let text = NSMutableAttributedString(
        attributedString: MarkdownTextRunRenderer.attributedString(
          for: [.paragraph(key.text)], theme: theme, foregroundColor: theme.textForeground
        ))
      let range = NSRange(location: 0, length: text.length)
      text.enumerateAttribute(.paragraphStyle, in: range) { value, range, _ in
        let style =
          (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
          ?? NSMutableParagraphStyle()
        switch key.alignment {
        case .center: style.alignment = .center
        case .trailing: style.alignment = .right
        case .none, .leading: style.alignment = .left
        }
        text.addAttribute(.paragraphStyle, value: style, range: range)
      }
      if key.isHeader {
        text.enumerateAttribute(.font, in: range) { value, range, _ in
          guard let font = value as? UIFont,
            let descriptor = font.fontDescriptor.withSymbolicTraits(
              font.fontDescriptor.symbolicTraits.union(.traitBold)
            )
          else { return }
          text.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: range)
        }
      }
      return text.copy() as! NSAttributedString
    }

    private static func minimumWidth(_ text: NSAttributedString) -> CGFloat {
      let source = text.string
      var width: CGFloat = 1
      var start = source.startIndex
      while start < source.endIndex {
        if source[start].isWhitespace { start = source.index(after: start); continue }
        let end = source[start...].firstIndex(where: \.isWhitespace) ?? source.endIndex
        width = max(width, text.attributedSubstring(from: NSRange(start..<end, in: source)).size().width)
        start = end
      }
      return ceil(width)
    }
  }
#endif
