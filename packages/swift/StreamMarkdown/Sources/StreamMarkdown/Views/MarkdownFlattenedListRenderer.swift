#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI

  /// Converts prose-only structural Markdown into one TextKit document.
  /// Lists and quotes can recurse through each other without creating a
  /// matching recursive SwiftUI layout tree. Truly embedded views (code,
  /// tables, and dividers) continue through `MarkdownRecursiveListView`.
  /// Converts prose-only structural Markdown into one TextKit document.
  /// Lists and quotes can recurse through each other without creating a
  /// matching recursive SwiftUI layout tree. Truly embedded views (code,
  /// tables, and dividers) continue through `MarkdownRecursiveListView`.
  /// Every list shape — the parser's simple bullet and ordered forms, full
  /// lists, and task lists — renders through `appendItems`, so they share
  /// one marker column and one hanging indent.
  enum MarkdownFlattenedListRenderer {
    private static let quoteIndent = MarkdownFragmentMetrics.quoteIndent

    private struct RenderContext {
      var contentIndent: CGFloat = 0
      var listDepth = 0
      /// Blocks directly inside a list item are spaced like list items.
      var isListItemContent = false
      var quoteBarOffsets: [CGFloat] = []

      func listItemContent(indentedBy amount: CGFloat) -> Self {
        var copy = self
        copy.contentIndent += amount
        copy.listDepth += 1
        copy.isListItemContent = true
        return copy
      }

      func quoted() -> Self {
        var copy = self
        copy.quoteBarOffsets.append(contentIndent)
        copy.contentIndent += quoteIndent
        copy.isListItemContent = false
        return copy
      }
    }

    private struct PendingMarker {
      let text: String
      let indent: CGFloat
    }

    private struct Item {
      let marker: String
      let blocks: [MarkdownBlock]
    }

    static func canRender(_ list: MarkdownList) -> Bool {
      list.items.allSatisfy { canRender($0.blocks) }
    }

    static func canRender(_ blocks: [MarkdownBlock]) -> Bool {
      blocks.allSatisfy { block in
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
          true
        case let .list(list):
          canRender(list)
        case let .blockQuote(blocks):
          canRender(blocks)
        case .codeBlock, .table, .thematicBreak:
          false
        }
      }
    }

    /// Renders a list or quote block that `canRender` accepts.
    static func attributedString(
      _ block: MarkdownBlock,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      var marker: PendingMarker?
      append(
        block,
        context: RenderContext(),
        pendingMarker: &marker,
        to: result,
        theme: theme,
        foreground: foreground,
        chipBackground: chipBackground
      )
      return result
    }
  }

  public extension MarkdownFragmentMetrics {
    /// The shared list column, measured for these markers in the body font.
    static func listColumn(markers: [String]) -> (markerInset: CGFloat, width: CGFloat) {
      listColumn(
        markerWidth: markers.map {
          ($0 as NSString).size(withAttributes: [.font: MarkdownTextRunRenderer.listMarkerFont(for: $0)]).width
        }.max() ?? 0
      )
    }
  }

  extension MarkdownFlattenedListRenderer {
    private static func appendItems(
      _ items: [Item],
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) {
      let column = MarkdownFragmentMetrics.listColumn(markers: items.map(\.marker))
      let contentContext = context.listItemContent(indentedBy: column.width)
      for (index, item) in items.enumerated() {
        if index > 0 {
          appendSpacing(
            theme.listItemSeparatorHeight,
            context: context,
            to: result,
            theme: theme,
            foreground: foreground
          )
        }
        var pendingMarker: PendingMarker? = PendingMarker(
          text: item.marker,
          indent: context.contentIndent + column.markerInset
        )
        append(
          item.blocks,
          context: contentContext,
          pendingMarker: &pendingMarker,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        // An empty item, or one that opens with a nested list, still shows
        // its own marker on a line of its own.
        appendPendingMarkerIfNeeded(
          &pendingMarker,
          context: contentContext,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
      }
    }

    private static func append(
      _ blocks: [MarkdownBlock],
      context: RenderContext,
      pendingMarker: inout PendingMarker?,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) {
      for (index, block) in blocks.enumerated() {
        if index > 0 {
          appendSpacing(
            context.isListItemContent
              ? theme.listItemSeparatorHeight
              : theme.blockSeparatorHeight(after: blocks[index - 1].role, before: block.role),
            context: context,
            to: result,
            theme: theme,
            foreground: foreground
          )
        }
        append(
          block,
          context: context,
          pendingMarker: &pendingMarker,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
      }
    }

    private static func append(
      _ block: MarkdownBlock,
      context: RenderContext,
      pendingMarker: inout PendingMarker?,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) {
      switch block {
      case let .heading(level, text):
        appendLine(
          marker: take(&pendingMarker),
          text: text,
          font: MarkdownTextRunRenderer.headingFont(for: level),
          context: context,
          to: result,
          theme: theme,
          foreground: MarkdownTextRunRenderer.headingForeground(for: level, theme: theme, body: foreground),
          chipBackground: chipBackground
        )

      case let .paragraph(text):
        appendLine(
          marker: take(&pendingMarker),
          text: text,
          font: MarkdownTextRunRenderer.bodyFont,
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case .bulletList, .orderedList, .list:
        appendPendingMarkerIfNeeded(
          &pendingMarker,
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        appendItems(
          items(of: block, depth: context.listDepth),
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .blockQuote(blocks):
        append(
          blocks,
          context: context.quoted(),
          pendingMarker: &pendingMarker,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case .codeBlock, .table, .thematicBreak:
        assertionFailure("Unsupported block reached flattened structural renderer")
      }
    }

    private static func items(of block: MarkdownBlock, depth: Int) -> [Item] {
      switch block {
      case let .bulletList(items):
        items.map { Item(marker: MarkdownList.bullet(depth: depth), blocks: [.paragraph($0)]) }
      case let .orderedList(items):
        items.map { Item(marker: "\($0.number).", blocks: [.paragraph($0.text)]) }
      case let .list(list):
        list.items.enumerated().map { index, item in
          Item(marker: list.marker(for: item, at: index, depth: depth), blocks: item.blocks)
        }
      default:
        []
      }
    }

    private static func appendPendingMarkerIfNeeded(
      _ marker: inout PendingMarker?,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) {
      guard let pending = take(&marker) else { return }
      appendLine(
        marker: pending,
        text: MarkdownText(""),
        font: MarkdownTextRunRenderer.bodyFont,
        context: context,
        to: result,
        theme: theme,
        foreground: foreground,
        chipBackground: chipBackground
      )
    }

    private static func appendLine(
      marker: PendingMarker?,
      text: MarkdownText,
      font: MarkdownNativeFont,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) {
      let line = NSMutableAttributedString()
      if let marker {
        line.append(
          NSAttributedString(
            string: "\(marker.text)\t",
            attributes: MarkdownTextRunRenderer.baseAttributes(
              font: MarkdownTextRunRenderer.listMarkerFont(for: marker.text),
              foreground: MarkdownNativeColor(theme.secondaryTextForeground),
              lineSpacing: theme.lineSpacing
            )
          )
        )
      }
      line.append(
        MarkdownTextRunRenderer.inlineAttributed(
          text,
          baseFont: font,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
      )

      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = theme.lineSpacing
      paragraph.firstLineHeadIndent = marker?.indent ?? context.contentIndent
      paragraph.headIndent = context.contentIndent
      if marker != nil {
        paragraph.tabStops = [
          NSTextTab(textAlignment: .left, location: context.contentIndent)
        ]
      }
      line.addAttribute(
        .paragraphStyle,
        value: paragraph,
        range: NSRange(location: 0, length: line.length)
      )
      appendDecorated(line, context: context, to: result, theme: theme)
    }

    private static func appendSpacing(
      _ height: CGFloat,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor
    ) {
      let separator = MarkdownTextRunRenderer.blockSeparator(
        height: height,
        ending: result,
        foreground: foreground
      )
      appendDecorated(separator, context: context, to: result, theme: theme)
    }

    private static func appendDecorated(
      _ value: NSAttributedString,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme
    ) {
      let start = result.length
      result.append(value)
      guard !context.quoteBarOffsets.isEmpty, result.length > start else { return }
      result.addAttribute(
        .streamMarkdownQuoteDecoration,
        value: TextKitQuoteDecoration(
          color: MarkdownNativeColor(theme.quoteBarColor),
          barOffsets: context.quoteBarOffsets
        ),
        range: NSRange(location: start, length: result.length - start)
      )
    }

    private static func take(_ marker: inout PendingMarker?) -> PendingMarker? {
      defer { marker = nil }
      return marker
    }

  }
#endif
