#if canImport(AppKit)
  import AppKit
  import SwiftUI

  enum MarkdownTableRenderer {
    struct PreparedCell {
      let attributedString: NSAttributedString
      let naturalWidth: CGFloat
      let minimumWidth: CGFloat
    }

    struct PreparedTable {
      let columnCount: Int
      let headers: [PreparedCell]
      let rows: [[PreparedCell]]
      let columnContentWidths: [CGFloat]
      let columnMinimumWidths: [CGFloat]
    }

    private static let horizontalPadding = MarkdownTableMetrics.horizontalPadding
    private static let verticalPadding = MarkdownTableMetrics.verticalPadding

    static func prepare(
      headers: [MarkdownText],
      rows: [[MarkdownText]],
      theme: MarkdownTheme,
      images: [String: MarkdownImageResource] = [:]
    ) -> PreparedTable {
      prepare(headers: headers, rows: rows, theme: theme) {
        markdown, isHeader, theme in
        prepareResolvedCell(markdown, isHeader: isHeader, theme: theme, images: images)
      }
    }

    static func prepare(
      headers: [MarkdownText],
      rows: [[MarkdownText]],
      theme: MarkdownTheme,
      cellProvider: (_ markdown: MarkdownText, _ isHeader: Bool, _ theme: MarkdownTheme) ->
        PreparedCell
    ) -> PreparedTable {
      let columnCount = max(headers.count, rows.map(\.count).max() ?? 0)
      guard columnCount > 0 else {
        return PreparedTable(
          columnCount: 0,
          headers: [],
          rows: [],
          columnContentWidths: [],
          columnMinimumWidths: []
        )
      }

      var contentWidths = [CGFloat](repeating: 1, count: columnCount)
      var minimumWidths = [CGFloat](repeating: 1, count: columnCount)
      func prepareRow(_ values: [MarkdownText], isHeader: Bool) -> [PreparedCell] {
        (0..<columnCount).map { column in
          let markdown = column < values.count ? values[column] : ""
          let cell = cellProvider(markdown, isHeader, theme)
          contentWidths[column] = max(contentWidths[column], cell.naturalWidth)
          minimumWidths[column] = max(minimumWidths[column], cell.minimumWidth)
          return cell
        }
      }

      let preparedHeaders = prepareRow(headers, isHeader: true)
      let preparedRows = rows.map { prepareRow($0, isHeader: false) }
      return PreparedTable(
        columnCount: columnCount,
        headers: preparedHeaders,
        rows: preparedRows,
        columnContentWidths: contentWidths,
        columnMinimumWidths: minimumWidths
      )
    }

    static func prepareResolvedCell(
      _ markdown: MarkdownText,
      isHeader: Bool,
      theme: MarkdownTheme,
      images: [String: MarkdownImageResource] = [:]
    ) -> PreparedCell {
      let attributed = inlineAttributed(markdown, isHeader: isHeader, theme: theme, images: images)
      let naturalWidth = max(1, ceil(attributed.size().width))
      return PreparedCell(
        attributedString: attributed,
        naturalWidth: naturalWidth,
        minimumWidth: min(minimumContentWidth(of: attributed), naturalWidth)
      )
    }

    private static func minimumContentWidth(of attributed: NSAttributedString) -> CGFloat {
      let string = attributed.string
      var widest: CGFloat = 1
      var index = string.startIndex
      while index < string.endIndex {
        if string[index].isWhitespace {
          index = string.index(after: index)
          continue
        }
        let start = index
        while index < string.endIndex, !string[index].isWhitespace {
          index = string.index(after: index)
        }
        let fragment = attributed.attributedSubstring(from: NSRange(start..<index, in: string))
        widest = max(widest, MarkdownImageAttachment.minimumWidth(of: fragment))
      }
      return ceil(widest)
    }

    static func make(
      prepared: PreparedTable,
      alignments: [ColumnAlignment],
      theme: MarkdownTheme,
      width: CGFloat? = nil
    ) -> NSAttributedString {
      guard prepared.columnCount > 0 else { return NSAttributedString() }
      let columnWidths = MarkdownTextTableGeometry.columns(
        MarkdownTableMetrics.distribute(
          contentWidths: prepared.columnContentWidths,
          minimumWidths: prepared.columnMinimumWidths,
          toFit: width.map(MarkdownTextTableGeometry.width),
          compressesBelowMinimums: false
        ))

      let table = NSTextTable()
      table.numberOfColumns = prepared.columnCount
      table.layoutAlgorithm = .fixedLayoutAlgorithm
      table.hidesEmptyCells = false

      let separatorColor = NSColor(theme.tableBorderColor)
      let headerBackground = NSColor.labelColor.withAlphaComponent(
        MarkdownTableMetrics.headerBackgroundOpacity
      )
      let lastRowIndex = prepared.rows.count

      let result = NSMutableAttributedString()
      appendRow(
        prepared.headers,
        rowIndex: 0,
        isHeader: true,
        columnCount: prepared.columnCount,
        alignments: alignments,
        columnWidths: columnWidths,
        table: table,
        separatorColor: separatorColor,
        headerBackground: headerBackground,
        lastRowIndex: lastRowIndex,
        into: result
      )
      for (offset, row) in prepared.rows.enumerated() {
        appendRow(
          row,
          rowIndex: offset + 1,
          isHeader: false,
          columnCount: prepared.columnCount,
          alignments: alignments,
          columnWidths: columnWidths,
          table: table,
          separatorColor: separatorColor,
          headerBackground: headerBackground,
          lastRowIndex: lastRowIndex,
          into: result
        )
      }
      return result
    }

    private static func appendRow(
      _ cells: [PreparedCell], rowIndex: Int, isHeader: Bool, columnCount: Int,
      alignments: [ColumnAlignment], columnWidths: [CGFloat], table: NSTextTable,
      separatorColor: NSColor, headerBackground: NSColor, lastRowIndex: Int,
      into result: NSMutableAttributedString
    ) {
      for column in 0..<columnCount {
        let alignment = column < alignments.count ? alignments[column] : .none

        let block = NSTextTableBlock(
          table: table, startingRow: rowIndex, rowSpan: 1,
          startingColumn: column, columnSpan: 1
        )
        block.setValue(columnWidths[column], type: .absoluteValueType, for: .width)
        block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(horizontalPadding, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(verticalPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
        if isHeader {
          block.backgroundColor = headerBackground
        }
        if rowIndex < lastRowIndex {
          block.setBorderColor(separatorColor, for: .maxY)
          block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.alignment = nsAlignment(alignment)

        let cell = NSMutableAttributedString(
          attributedString: MarkdownImageAttachment.fitting(cells[column].attributedString, width: columnWidths[column])
        )
        cell.append(NSAttributedString(string: "\n"))
        cell.addAttribute(
          .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: cell.length)
        )
        result.append(cell)
      }
    }

    private static func inlineAttributed(
      _ markdown: MarkdownText, isHeader: Bool, theme: MarkdownTheme, images: [String: MarkdownImageResource]
    ) -> NSAttributedString {
      let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
      let baseFont = NSFont.systemFont(ofSize: bodySize, weight: isHeader ? .semibold : .regular)
      let codeFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular
      )
      let codeBackground = NSColor(theme.inlineCodeBackground)

      let parsed = InlineMarkdown.tableAttributedString(from: markdown)
      let output = NSMutableAttributedString()
      for run in parsed.runs {
        let substring = String(parsed[run.range].characters)
        guard !substring.isEmpty else { continue }
        let intent = run.inlinePresentationIntent

        var attributes = inlineAttributes(
          intent: intent, baseFont: baseFont, codeFont: codeFont, codeBackground: codeBackground)
        if let link = run.link {
          if markdownUsesServerFileLinkAttribute(link) {
            attributes[.streamMarkdownServerFileLink] = link
            attributes[.cursor] = NSCursor.pointingHand
          } else {
            attributes[.link] = link
          }
          attributes[.foregroundColor] = NSColor.linkColor
        }
        if let reference = run[MarkdownImageReferenceAttribute.self] {
          output.append(
            MarkdownImageAttachment.content(reference, resource: images[reference.source], attributes: attributes))
        } else {
          output.append(NSAttributedString(string: substring, attributes: attributes))
        }
      }
      return output
    }

    private static func inlineAttributes(
      intent: InlinePresentationIntent?,
      baseFont: NSFont,
      codeFont: NSFont,
      codeBackground: NSColor
    ) -> [NSAttributedString.Key: Any] {
      var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor]
      if intent?.contains(.code) == true {
        attributes[.font] = codeFont
        attributes[.backgroundColor] = codeBackground
      } else {
        attributes[.font] = styled(
          baseFont,
          bold: intent?.contains(.stronglyEmphasized) == true,
          italic: intent?.contains(.emphasized) == true
        )
      }
      if intent?.contains(.strikethrough) == true {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      return attributes
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
      guard bold || italic else { return font }
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.bold) }
      if italic { traits.insert(.italic) }
      let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
      return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func nsAlignment(_ alignment: ColumnAlignment) -> NSTextAlignment {
      switch alignment {
      case .leading, .none: return .left
      case .center: return .center
      case .trailing: return .right
      }
    }
  }
#endif
