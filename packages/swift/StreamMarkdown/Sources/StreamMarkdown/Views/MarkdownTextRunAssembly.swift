#if canImport(AppKit) || canImport(UIKit)
  import MarkdownCore
  import SwiftUI

  struct MarkdownTextRunAssembly {
    private var text = NSMutableAttributedString()
    private var previous: MarkdownBlock?
    private let theme: MarkdownTheme
    private let foreground: MarkdownNativeColor
    private let chipBackground: MarkdownNativeChipBackground

    init(_ blocks: some Sequence<MarkdownBlock>, theme: MarkdownTheme, foregroundColor: Color) {
      self.theme = theme
      foreground = MarkdownNativeColor(foregroundColor)
      chipBackground = MarkdownNativeChipBackground(
        color: MarkdownNativeColor(theme.inlineCodeBackground),
        cornerRadius: theme.inlineCodeCornerRadius
      )
      for block in blocks {
        append(block)
      }
    }

    private mutating func append(_ block: MarkdownBlock) {
      let piece = MarkdownTextRunRenderer.attributedString(
        for: block, theme: theme, foreground: foreground, chipBackground: chipBackground)
      guard piece.length > 0 else { return }

      if let previous {
        let height = theme.blockSeparatorHeight(after: previous.role, before: block.role)
        text.append(MarkdownTextRunRenderer.blockSeparator(height: height, ending: text, foreground: foreground))
      }
      text.append(piece)
      previous = block
    }

    func appending(_ block: MarkdownBlock) -> MarkdownTextRunAssembly {
      var copy = self
      copy.text = NSMutableAttributedString(attributedString: text)
      copy.append(block)
      return copy
    }

    var snapshot: NSAttributedString {
      text.copy() as! NSAttributedString
    }
  }
#endif
