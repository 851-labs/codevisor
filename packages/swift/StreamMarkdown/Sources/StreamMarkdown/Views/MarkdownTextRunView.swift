#if canImport(AppKit) || canImport(UIKit)
  import SwiftUI

  /// Renders consecutive text-like Markdown blocks in one native TextKit view.
  /// A single text storage keeps selection continuous across headings,
  /// paragraphs, and lists without SwiftUI changing layout engines on click.
  struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    let animationContext: StreamingTextAnimationContext?
    @Environment(\.markdownTheme) private var theme
    /// Reuse the attributed string for unchanged blocks. Equality still compares
    /// the block values; a hit avoids rebuilding attributes and native layout.
    @State private var memo = TextRunMemo()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
      let _ = dynamicTypeSize
      SelectableTextView(
        attributedText: memo.rendered(
          for: blocks,
          theme: theme,
          foregroundColor: foregroundColor
        ),
        streamingAnimation: animationContext
      )
    }
  }

  /// Converts parsed Markdown runs to native attributes. Font choices match the
  /// semantic SwiftUI styles previously used by `MarkdownTextRunView`; the host
  /// does not override MarkdownTheme's fonts today (tables follow the same
  /// semantic-font contract).
  enum MarkdownTextRunRenderer {
    static func attributedString(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foregroundColor: Color
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let foreground = MarkdownNativeColor(foregroundColor)
      let chipBackground = MarkdownNativeChipBackground(
        color: MarkdownNativeColor(theme.inlineCodeBackground),
        cornerRadius: theme.inlineCodeCornerRadius
      )

      for (index, block) in blocks.enumerated() {
        let piece = attributedString(
          for: block,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        guard piece.length > 0 else { continue }
        if index > 0, result.length > 0 {
          result.append(
            verticalSeparator(
              size: max(2, (theme.blockSpacing - 2 * theme.lineSpacing) * 0.8),
              lineSpacing: theme.lineSpacing,
              foreground: foreground
            )
          )
        }
        result.append(piece)
      }
      return result.copy() as! NSAttributedString
    }

    private static func attributedString(
      for block: MarkdownBlock,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) -> NSAttributedString {
      switch block {
      case let .heading(level, text):
        inlineAttributed(
          text,
          baseFont: headingFont(for: level),
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .paragraph(text):
        inlineAttributed(
          text,
          baseFont: bodyFont,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .bulletList(items):
        list(
          items: items.map { (marker: "•", text: $0) },
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .orderedList(items):
        list(
          items: items.map { (marker: "\($0.number).", text: $0.text) },
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case let .list(list):
        if let items = simpleListItems(list) {
          self.list(
            items: items,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )
        } else {
          MarkdownFlattenedListRenderer.attributedString(
            list,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )
        }

      case let .blockQuote(blocks):
        MarkdownFlattenedListRenderer.attributedString(
          blockQuote: blocks,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case .codeBlock, .table, .thematicBreak:
        NSAttributedString()
      }
    }

    /// A tight list whose items are each one paragraph — or, mid-stream,
    /// still empty — is the parser's simple list shape in all but name.
    /// Rendering it through the simple path keeps one marker geometry
    /// while a streaming list flips between the two forms as items land.
    private static func simpleListItems(
      _ list: MarkdownList
    ) -> [(marker: String, text: MarkdownText)]? {
      guard list.isTight else { return nil }
      var items: [(marker: String, text: MarkdownText)] = []
      for (index, item) in list.items.enumerated() {
        guard !item.isTask else { return nil }
        let marker = list.marker(for: item, at: index)
        switch item.blocks.count {
        case 0:
          items.append((marker: marker, text: MarkdownText("")))
        case 1:
          guard case let .paragraph(text) = item.blocks[0] else { return nil }
          items.append((marker: marker, text: text))
        default:
          return nil
        }
      }
      return items
    }

    static func canRenderFlattenedList(_ list: MarkdownList) -> Bool {
      MarkdownFlattenedListRenderer.canRender(list)
    }

    static func canRenderFlattenedText(_ blocks: [MarkdownBlock]) -> Bool {
      MarkdownFlattenedListRenderer.canRender(blocks)
    }

    private static func list(
      items: [(marker: String, text: MarkdownText)],
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      for (index, item) in items.enumerated() {
        if index > 0 {
          result.append(
            verticalSeparator(
              size: max(1, (theme.listItemSpacing - 2 * theme.lineSpacing) * 0.8),
              lineSpacing: theme.lineSpacing,
              foreground: foreground
            )
          )
        }
        result.append(
          NSAttributedString(
            string: "\(item.marker) ",
            attributes: baseAttributes(
              font: bodyFont,
              foreground: MarkdownNativeColor(theme.secondaryTextForeground),
              lineSpacing: theme.lineSpacing
            )
          )
        )
        result.append(
          inlineAttributed(
            item.text,
            baseFont: bodyFont,
            theme: theme,
            foreground: foreground,
            chipBackground: chipBackground
          )
        )
      }
      return result
    }

    static func inlineAttributed(
      _ markdown: MarkdownText,
      baseFont: MarkdownNativeFont,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground
    ) -> NSAttributedString {
      let parsed = InlineMarkdown.attributedString(from: markdown, theme: theme)
      let output = NSMutableAttributedString()
      let codeFont = MarkdownNativeTypography.codeFont

      for run in parsed.runs {
        let substring = String(parsed[run.range].characters)
        guard !substring.isEmpty else { continue }
        let intent = run.inlinePresentationIntent
        let isCode =
          run[InlineCodeChipAttribute.self] == true
          || intent?.contains(.code) == true
        let font =
          isCode
          ? codeFont
          : styled(
            baseFont,
            bold: intent?.contains(.stronglyEmphasized) == true,
            italic: intent?.contains(.emphasized) == true
          )
        var attributes = baseAttributes(
          font: font,
          foreground: run.link == nil ? foreground : MarkdownNativeTypography.linkColor,
          lineSpacing: theme.lineSpacing
        )
        if intent?.contains(.strikethrough) == true {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
          MarkdownNativeTypography.installLink(link, into: &attributes)
        }
        if isCode {
          attributes[.streamMarkdownRoundedBackground] = chipBackground
        }
        output.append(NSAttributedString(string: substring, attributes: attributes))
      }
      return output
    }

    static func verticalSeparator(
      size: CGFloat,
      lineSpacing: CGFloat,
      foreground: MarkdownNativeColor
    ) -> NSAttributedString {
      NSAttributedString(
        string: "\n\n",
        attributes: baseAttributes(
          font: .systemFont(ofSize: size),
          foreground: foreground,
          lineSpacing: lineSpacing
        )
      )
    }

    static func baseAttributes(
      font: MarkdownNativeFont,
      foreground: MarkdownNativeColor,
      lineSpacing: CGFloat
    ) -> [NSAttributedString.Key: Any] {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = lineSpacing
      return [
        .font: font,
        .foregroundColor: foreground,
        .paragraphStyle: paragraph,
      ]
    }

    static var bodyFont: MarkdownNativeFont {
      .preferredFont(forTextStyle: .body)
    }

    static func headingFont(for level: Int) -> MarkdownNativeFont {
      MarkdownNativeTypography.headingFont(for: level)
    }

    private static func styled(_ font: MarkdownNativeFont, bold: Bool, italic: Bool) -> MarkdownNativeFont {
      MarkdownNativeTypography.styled(font, bold: bold, italic: italic)
    }
  }

  /// Last-value memo for the immutable attributed string handed to both the
  /// displayed TextKit view and its scratch measurer. Returning the same object
  /// identity lets the native consumers skip resetting unchanged text storage.
  @MainActor
  private final class TextRunMemo {
    private var blocks: [MarkdownBlock]?
    private var themeFingerprint: Int?
    private var foregroundColor: Color?
    private var cached: NSAttributedString?

    func rendered(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foregroundColor: Color
    ) -> NSAttributedString {
      let fingerprint = theme.renderFingerprint ^ MarkdownTextRunRenderer.bodyFont.pointSize.hashValue
      if let cached,
        blocks == self.blocks,
        fingerprint == themeFingerprint,
        foregroundColor == self.foregroundColor
      {
        return cached
      }
      let cacheKey = MarkdownTextRunCache.Key(
        blocks: blocks,
        themeFingerprint: fingerprint,
        foregroundColor: .init(foregroundColor)
      )
      if let rendered = MarkdownTextRunCache.shared.value(for: cacheKey) {
        self.blocks = blocks
        themeFingerprint = fingerprint
        self.foregroundColor = foregroundColor
        cached = rendered
        return rendered
      }
      let rendered = MarkdownTextRunRenderer.attributedString(
        for: blocks,
        theme: theme,
        foregroundColor: foregroundColor
      )
      MarkdownTextRunCache.shared.store(rendered, for: cacheKey)
      self.blocks = blocks
      themeFingerprint = fingerprint
      self.foregroundColor = foregroundColor
      cached = rendered
      return rendered
    }
  }

#endif
