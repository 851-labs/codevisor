#if canImport(AppKit) || canImport(UIKit)
  import CoreGraphics
  import MarkdownCore

  public extension MarkdownTheme {
    static var spacingUnit: CGFloat { MarkdownTextRunRenderer.bodyFont.pointSize }

    func blockGap(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
      guard previous != nil else { return 0 }
      return lineSpacing + blockSeparatorHeight(after: previous, before: next)
    }

    var listItemGap: CGFloat { lineSpacing + listItemSeparatorHeight }

    func gap(_ trailing: MarkdownFragmentLayout.TrailingSpacing) -> CGFloat {
      switch trailing {
      case .none: 0
      case let .block(previous, next): blockGap(after: previous, before: next)
      case .listItem: listItemGap
      }
    }
  }

  extension MarkdownTheme {
    var lineSpacing: CGFloat {
      let font = MarkdownTextRunRenderer.bodyFont
      return max(0, font.pointSize * spacing.lineHeight - (font.ascender - font.descender))
    }

    func blockSeparatorHeight(after previous: MarkdownBlockRole?, before next: MarkdownBlockRole) -> CGFloat {
      spacing.gap(after: previous, before: next) * Self.spacingUnit
    }

    var listItemSeparatorHeight: CGFloat { spacing.listItem * Self.spacingUnit }
  }
#endif
