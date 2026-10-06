#if canImport(AppKit) || canImport(UIKit)
  import CoreGraphics
  import MarkdownCore

  public extension MarkdownTheme {
    /// Points per `MarkdownSpacing` unit: the body font size, which follows
    /// Dynamic Type on iOS, so every gap scales with the text it separates.
    static var spacingUnit: CGFloat { MarkdownTextRunRenderer.bodyFont.pointSize }

    /// Space in points between two blocks rendered by separate views. A
    /// measured text view ends at its last line's glyphs, so this restores
    /// the leading below that line before adding the gap itself; the same
    /// boundary inside one TextKit run comes out identical.
    func blockGap(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
      guard previous != nil else { return 0 }
      return lineSpacing + blockSeparatorHeight(after: previous, before: next)
    }

    /// Space in points between list items, and between the blocks of one
    /// item, rendered by separate views.
    var listItemGap: CGFloat { lineSpacing + listItemSeparatorHeight }

    /// Space in points below a transcript fragment row.
    func gap(_ trailing: MarkdownFragmentLayout.TrailingSpacing) -> CGFloat {
      switch trailing {
      case .none: 0
      case let .block(previous, next): blockGap(after: previous, before: next)
      case .listItem: listItemGap
      }
    }
  }

  extension MarkdownTheme {
    /// Paragraph line spacing for every line: lines of body text advance by
    /// the theme's line height. TextKit advances by ascender and descender
    /// (font leading is disabled) plus this.
    var lineSpacing: CGFloat {
      let font = MarkdownTextRunRenderer.bodyFont
      return max(0, font.pointSize * spacing.lineHeight - (font.ascender - font.descender))
    }

    /// Height of the empty paragraph between two blocks in one TextKit run,
    /// where the preceding line already carries its leading.
    func blockSeparatorHeight(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
      spacing.gap(after: previous, before: next) * Self.spacingUnit
    }

    var listItemSeparatorHeight: CGFloat { spacing.listItem * Self.spacingUnit }
  }
#endif
