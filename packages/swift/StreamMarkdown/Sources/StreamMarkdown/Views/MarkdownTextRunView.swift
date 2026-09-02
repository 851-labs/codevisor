// The AppKit/TextKit rendering layer. iOS uses the matching UIKit/TextKit
// implementation in `MarkdownTextRunView+UIKit.swift`.
#if canImport(AppKit)
  import AppKit
  import SwiftUI

  /// Renders consecutive text-like Markdown blocks in one native TextKit view.
  /// A single text storage keeps selection continuous across headings,
  /// paragraphs, and lists without SwiftUI changing layout engines on click.
  struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    let animationContext: StreamingTextAnimationContext?
    @Environment(\.markdownTheme) private var theme
    /// The parse coordinator value-stabilizes unchanged blocks, so this memo makes
    /// repeated transcript body evaluations O(1) for unchanged text.
    @State private var memo = TextRunMemo()

    var body: some View {
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

  /// Converts parsed Markdown runs to AppKit attributes. Font choices match the
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
      let foreground = NSColor(foregroundColor)
      let chipBackground = TextKitRoundedBackground(
        color: NSColor(theme.inlineCodeBackground),
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
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
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
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
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
              foreground: NSColor(theme.secondaryTextForeground),
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
      baseFont: NSFont,
      theme: MarkdownTheme,
      foreground: NSColor,
      chipBackground: TextKitRoundedBackground
    ) -> NSAttributedString {
      let parsed = InlineMarkdown.attributedString(from: markdown, theme: theme)
      let output = NSMutableAttributedString()
      let codeFont = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
        weight: .regular
      )

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
          foreground: run.link == nil ? foreground : .linkColor,
          lineSpacing: theme.lineSpacing
        )
        if intent?.contains(.strikethrough) == true {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
          if markdownUsesServerFileLinkAttribute(link) {
            attributes[.streamMarkdownServerFileLink] = link
            attributes[.cursor] = NSCursor.pointingHand
          } else {
            attributes[.link] = link
          }
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
      foreground: NSColor
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
      font: NSFont,
      foreground: NSColor,
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

    static var bodyFont: NSFont {
      .preferredFont(forTextStyle: .body)
    }

    static func headingFont(for level: Int) -> NSFont {
      let style: NSFont.TextStyle =
        switch level {
        case 1: .title1
        case 2: .title2
        case 3: .title3
        case 4: .headline
        default: .subheadline
        }
      return styled(.preferredFont(forTextStyle: style), bold: true, italic: false)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
      guard bold || italic else { return font }
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.bold) }
      if italic { traits.insert(.italic) }
      let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
      return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
  }

  /// Last-value memo for the immutable attributed string handed to both the
  /// displayed TextKit view and its scratch measurer. Returning the same object
  /// identity lets both paths skip unchanged Markdown in O(1).
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
      let fingerprint = theme.renderFingerprint
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
