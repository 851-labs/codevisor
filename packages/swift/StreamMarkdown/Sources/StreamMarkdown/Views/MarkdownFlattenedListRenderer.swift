#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// Converts prose-only structural Markdown into one TextKit document.
  /// Lists and quotes can recurse through each other without creating a
  /// matching recursive SwiftUI layout tree. Truly embedded views (code,
  /// tables, and dividers) continue through `MarkdownRecursiveListView`.
  enum MarkdownFlattenedListRenderer {
    private static let listIndent: CGFloat = 24
    private static let listMarkerWidth: CGFloat = 22
    private static let quoteIndent: CGFloat = 11

    private struct RenderContext {
      var contentIndent: CGFloat = 0
      var quoteBarOffsets: [CGFloat] = []

      func indented(by amount: CGFloat) -> Self {
        var copy = self
        copy.contentIndent += amount
        return copy
      }

      func quoted() -> Self {
        var copy = self
        copy.quoteBarOffsets.append(contentIndent)
        copy.contentIndent += quoteIndent
        return copy
      }
    }

    private struct PendingMarker {
      let text: String
      let indent: CGFloat
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

    static func attributedString(
      _ list: MarkdownList,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      append(
        list,
        context: RenderContext(),
        to: result,
        theme: theme,
        foreground: foreground,
        chipBackground: chipBackground
      )
      return result
    }

    static func attributedString(
      blockQuote blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      var marker: PendingMarker?
      append(
        blocks,
        context: RenderContext().quoted(),
        pendingMarker: &marker,
        to: result,
        theme: theme,
        foreground: foreground,
        chipBackground: chipBackground
      )
      return result
    }
  }

  extension MarkdownFlattenedListRenderer {
    private static func append(
      _ list: MarkdownList,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) {
      for (itemIndex, item) in list.items.enumerated() {
        if itemIndex > 0 {
          appendSpacing(
            context: context,
            to: result,
            theme: theme,
            foreground: foreground
          )
        }
        append(
          item,
          marker: list.marker(for: item, at: itemIndex),
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
      }
    }

    private static func append(
      _ item: MarkdownListItem,
      marker: String,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) {
      var pendingMarker: PendingMarker? = PendingMarker(
        text: marker,
        indent: context.contentIndent
      )
      guard !item.blocks.isEmpty else {
        appendLine(
          marker: pendingMarker,
          text: MarkdownText(""),
          font: MarkdownTextRunRenderer.bodyFont,
          context: context.indented(by: listMarkerWidth),
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        return
      }

      let contentContext = context.indented(by: listMarkerWidth)
      for (blockIndex, block) in item.blocks.enumerated() {
        if blockIndex > 0 {
          appendSpacing(
            context: contentContext,
            to: result,
            theme: theme,
            foreground: foreground
          )
        }
        switch block {
        case let .list(nested):
          appendPendingMarkerIfNeeded(
            &pendingMarker,
            context: contentContext,
            to: result,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )
          append(
            nested,
            context: context.indented(by: listIndent),
            to: result,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )

        case let .bulletList(items):
          let nestedContext =
            pendingMarker == nil ? context.indented(by: listIndent) : context
          pendingMarker = nil
          appendCompatibilityList(
            items.map { ("•", $0) },
            context: nestedContext,
            to: result,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )

        case let .orderedList(items):
          let nestedContext =
            pendingMarker == nil ? context.indented(by: listIndent) : context
          pendingMarker = nil
          appendCompatibilityList(
            items.map { ("\($0.number).", $0.text) },
            context: nestedContext,
            to: result,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )

        default:
          append(
            block,
            context: contentContext,
            pendingMarker: &pendingMarker,
            to: result,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )
        }
      }
      appendPendingMarkerIfNeeded(
        &pendingMarker,
        context: contentContext,
        to: result,
        theme: theme,
        foreground: foreground,
        chipBackground: chipBackground
      )
    }

    private static func append(
      _ blocks: [MarkdownBlock],
      context: RenderContext,
      pendingMarker: inout PendingMarker?,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) {
      for (index, block) in blocks.enumerated() {
        if index > 0 {
          appendSpacing(
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
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
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
          foreground: foreground,
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

      case let .bulletList(items):
        appendPendingMarkerIfNeeded(
          &pendingMarker,
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        appendCompatibilityList(
          items.map { ("•", $0) },
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .orderedList(items):
        appendPendingMarkerIfNeeded(
          &pendingMarker,
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        appendCompatibilityList(
          items.map { ("\($0.number).", $0.text) },
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .list(list):
        appendPendingMarkerIfNeeded(
          &pendingMarker,
          context: context,
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        append(
          list,
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

    private static func appendCompatibilityList(
      _ items: [(String, MarkdownText)],
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) {
      for (index, item) in items.enumerated() {
        if index > 0 {
          appendSpacing(
            context: context,
            to: result,
            theme: theme,
            foreground: foreground
          )
        }
        appendLine(
          marker: PendingMarker(text: item.0, indent: context.contentIndent),
          text: item.1,
          font: MarkdownTextRunRenderer.bodyFont,
          context: context.indented(by: listMarkerWidth),
          to: result,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
      }
    }

    private static func appendPendingMarkerIfNeeded(
      _ marker: inout PendingMarker?,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
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
      font: NSFont,
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) {
      let line = NSMutableAttributedString()
      if let marker {
        line.append(
          NSAttributedString(
            string: "\(marker.text)\t",
            attributes: MarkdownTextRunRenderer.baseAttributes(
              font: MarkdownTextRunRenderer.bodyFont,
              foreground: NSColor(theme.secondaryTextForeground),
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
      context: RenderContext,
      to result: NSMutableAttributedString,
      theme: MarkdownTheme,
      foreground: NSColor
    ) {
      let separator = MarkdownTextRunRenderer.verticalSeparator(
        size: max(1, (theme.listItemSpacing - 2 * theme.lineSpacing) * 0.8),
        lineSpacing: theme.lineSpacing,
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
          color: NSColor(theme.quoteBarColor),
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
