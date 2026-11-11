#if canImport(AppKit) || canImport(UIKit)
  import MarkdownCore
  import SwiftUI

  struct MarkdownTextRunView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    let animationContext: StreamingTextAnimationContext?
    @Environment(\.markdownTheme) private var theme
    @State private var memo = MarkdownTextRunMemo()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var usesPreparedLayout: Bool

    init(blocks: [MarkdownBlock], foregroundColor: Color, animationContext: StreamingTextAnimationContext?) {
      self.blocks = blocks
      self.foregroundColor = foregroundColor
      self.animationContext = animationContext
      _usesPreparedLayout = State(
        initialValue: animationContext == nil && MarkdownLayoutPolicy.requiresBackgroundTextLayout(blocks))
    }

    var body: some View {
      let _ = dynamicTypeSize
      if usesPreparedLayout {
        PreparedSelectableTextView(blocks: blocks, theme: theme, foregroundColor: foregroundColor)
      } else {
        SelectableTextView(
          attributedText: memo.rendered(for: blocks, theme: theme, foregroundColor: foregroundColor),
          streamingAnimation: animationContext
        )
      }
    }
  }

  enum MarkdownTextRunRenderer {
    static func attributedString(
      for blocks: [MarkdownBlock],
      theme: MarkdownTheme,
      foregroundColor: Color
    ) -> NSAttributedString {
      MarkdownTextRunAssembly(blocks, theme: theme, foregroundColor: foregroundColor).snapshot
    }

    static func attributedString(
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
          foreground: headingForeground(for: level, theme: theme, body: foreground),
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

      case .bulletList, .orderedList, .list, .blockQuote:
        MarkdownFlattenedListRenderer.attributedString(
          block,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )

      case .codeBlock, .table, .thematicBreak:
        NSAttributedString()
      }
    }

    static func canRenderFlattenedList(_ list: MarkdownList) -> Bool {
      MarkdownFlattenedListRenderer.canRender(list)
    }

    static func canRenderFlattenedText(_ blocks: [MarkdownBlock]) -> Bool {
      MarkdownFlattenedListRenderer.canRender(blocks)
    }

    static func inlineAttributed(
      _ markdown: MarkdownText,
      baseFont: MarkdownNativeFont,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground,
      images: [String: MarkdownImageResource]? = nil
    ) -> NSAttributedString {
      guard images == nil else {
        return renderInline(
          markdown, baseFont: baseFont, theme: theme, foreground: foreground, chipBackground: chipBackground,
          images: images)
      }

      let key = MarkdownInlineRenderCache.Key(
        markdown: markdown, font: baseFont, foreground: foreground, chipColor: chipBackground.color,
        chipCornerRadius: chipBackground.cornerRadius, themeFingerprint: theme.renderFingerprint)
      return MarkdownInlineRenderCache.shared.text(for: key) {
        renderInline(
          markdown, baseFont: baseFont, theme: theme, foreground: foreground, chipBackground: chipBackground,
          images: nil)
      }
    }

    private static func renderInline(
      _ markdown: MarkdownText,
      baseFont: MarkdownNativeFont,
      theme: MarkdownTheme,
      foreground: MarkdownNativeColor,
      chipBackground: MarkdownNativeChipBackground,
      images: [String: MarkdownImageResource]?
    ) -> NSAttributedString {
      let parsed =
        images == nil
        ? InlineMarkdown.attributedString(from: markdown, theme: theme)
        : InlineMarkdown.styleInlineCode(in: InlineMarkdown.tableAttributedString(from: markdown), theme: theme)
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
        if let reference = run[MarkdownImageReferenceAttribute.self] {
          output.append(
            MarkdownImageAttachment.content(reference, resource: images?[reference.source], attributes: attributes))
        } else {
          output.append(NSAttributedString(string: substring, attributes: attributes))
        }
      }
      return output.copy() as! NSAttributedString
    }

    static func blockSeparator(
      height: CGFloat,
      ending text: NSAttributedString,
      foreground: MarkdownNativeColor
    ) -> NSAttributedString {
      let font = MarkdownNativeFont.systemFont(ofSize: 1)
      var terminator: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
      if text.length > 0 {
        terminator[.paragraphStyle] = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil)
      }
      let gap = NSMutableParagraphStyle()
      gap.minimumLineHeight = height
      gap.maximumLineHeight = height
      let separator = NSMutableAttributedString(string: "\n", attributes: terminator)
      separator.append(
        NSAttributedString(
          string: "\n",
          attributes: [.font: font, .foregroundColor: foreground, .paragraphStyle: gap]
        )
      )
      return separator
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
      BodyTextMetrics.font
    }

    static func listMarkerFont(for marker: String) -> MarkdownNativeFont {
      styled(bodyFont, bold: MarkdownList.isBullet(marker), italic: false)
    }

    static func headingFont(for level: Int) -> MarkdownNativeFont {
      MarkdownNativeTypography.headingFont(for: level)
    }

    static func headingForeground(
      for level: Int,
      theme: MarkdownTheme,
      body: MarkdownNativeColor
    ) -> MarkdownNativeColor {
      level >= 5 ? MarkdownNativeColor(theme.secondaryTextForeground) : body
    }

    private static func styled(_ font: MarkdownNativeFont, bold: Bool, italic: Bool) -> MarkdownNativeFont {
      MarkdownNativeTypography.styled(font, bold: bold, italic: italic)
    }
  }

#endif
