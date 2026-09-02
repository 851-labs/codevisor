#if canImport(UIKit) && !canImport(AppKit)
  import SwiftUI
  import UIKit

  /// Renders consecutive prose blocks in one native UIKit/TextKit view. The
  /// storage remains selectable while the custom layout manager performs the
  /// streamed word fade.
  struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    let animationContext: StreamingTextAnimationContext?
    @Environment(\.markdownTheme) private var theme
    @State private var memo = UIKitTextRunMemo()

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

  enum UIKitMarkdownTextRunRenderer {
    static func attributedString(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foregroundColor: Color
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let foreground = UIColor(foregroundColor)
      let chipBackground = UIKitTextKitRoundedBackground(
        color: UIColor(theme.inlineCodeBackground),
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
      foreground: UIColor,
      chipBackground: UIKitTextKitRoundedBackground
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

      case .codeBlock, .list, .blockQuote, .table, .thematicBreak:
        NSAttributedString()
      }
    }

    private static func list(
      items: [(marker: String, text: MarkdownText)],
      theme: MarkdownTheme,
      foreground: UIColor,
      chipBackground: UIKitTextKitRoundedBackground
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
              foreground: UIColor(theme.secondaryTextForeground),
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

    private static func inlineAttributed(
      _ markdown: MarkdownText,
      baseFont: UIFont,
      theme: MarkdownTheme,
      foreground: UIColor,
      chipBackground: UIKitTextKitRoundedBackground
    ) -> NSAttributedString {
      let parsed = InlineMarkdown.attributedString(from: markdown, theme: theme)
      let output = NSMutableAttributedString()
      let codeFont = UIFont.scaledMonospacedSystemFont(forTextStyle: .callout)

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
          foreground: run.link == nil ? foreground : .link,
          lineSpacing: theme.lineSpacing
        )
        if intent?.contains(.strikethrough) == true {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = run.link {
          attributes[.link] = link
        }
        if isCode {
          attributes[.streamMarkdownRoundedBackground] = chipBackground
        }
        output.append(NSAttributedString(string: substring, attributes: attributes))
      }
      return output
    }

    private static func verticalSeparator(
      size: CGFloat,
      lineSpacing: CGFloat,
      foreground: UIColor
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

    private static func baseAttributes(
      font: UIFont,
      foreground: UIColor,
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

    private static var bodyFont: UIFont {
      .preferredFont(forTextStyle: .body)
    }

    static func headingFont(for level: Int) -> UIFont {
      let style: UIFont.TextStyle =
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
      return styled(.preferredFont(forTextStyle: style), bold: true, italic: false)
    }

    private static func styled(_ font: UIFont, bold: Bool, italic: Bool) -> UIFont {
      guard bold || italic else { return font }
      var traits = font.fontDescriptor.symbolicTraits
      if bold { traits.insert(.traitBold) }
      if italic { traits.insert(.traitItalic) }
      guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
        return font
      }
      return UIFont(descriptor: descriptor, size: font.pointSize)
    }
  }

  @MainActor
  private final class UIKitTextRunMemo {
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
      let rendered = UIKitMarkdownTextRunRenderer.attributedString(
        for: blocks,
        theme: theme,
        foregroundColor: foregroundColor
      )
      self.blocks = blocks
      themeFingerprint = fingerprint
      self.foregroundColor = foregroundColor
      cached = rendered
      return rendered
    }
  }
#endif
