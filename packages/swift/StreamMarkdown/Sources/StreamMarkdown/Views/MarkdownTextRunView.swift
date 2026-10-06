#if canImport(AppKit) || canImport(UIKit)
  import MarkdownCore
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

      var previous: MarkdownBlock?
      for block in blocks {
        let piece = attributedString(
          for: block,
          theme: theme,
          foreground: foreground,
          chipBackground: chipBackground
        )
        guard piece.length > 0 else { continue }
        if let previous {
          result.append(
            blockSeparator(
              height: theme.blockSeparatorHeight(after: previous.role, before: block.role),
              ending: result,
              foreground: foreground
            )
          )
        }
        result.append(piece)
        previous = block
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
      return output
    }

    /// Ends the paragraph `text` finishes with and adds an empty paragraph
    /// exactly `height` points tall. The blank line keeps copied text
    /// readable; its fixed height makes the gap independent of font
    /// metrics. The terminator keeps the preceding paragraph's style so the
    /// line spacing below its last line matches every other line.
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
      .preferredFont(forTextStyle: .body)
    }

    static func listMarkerFont(for marker: String) -> MarkdownNativeFont {
      styled(bodyFont, bold: MarkdownList.isBullet(marker), italic: false)
    }

    static func headingFont(for level: Int) -> MarkdownNativeFont {
      MarkdownNativeTypography.headingFont(for: level)
    }

    /// H5 and H6 sit below body text in size, so color carries their rank.
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
