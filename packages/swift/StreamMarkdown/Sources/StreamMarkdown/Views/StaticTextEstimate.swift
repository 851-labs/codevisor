import CoreGraphics
import MarkdownCore

enum StaticTextEstimate {
  static let averageCharacterWidth: CGFloat = 7.4
  static let lineHeight: CGFloat = 20
  static let paragraphGap: CGFloat = 10

  static func height(of blocks: [MarkdownBlock], theme _: MarkdownTheme, width: CGFloat) -> CGFloat {
    let charactersPerLine = max(1, Int(width / averageCharacterWidth))
    let lines = blocks.reduce(0) { total, block in
      total + max(1, (characterCount(block) + charactersPerLine - 1) / charactersPerLine)
    }
    return CGFloat(lines) * lineHeight + CGFloat(max(0, blocks.count - 1)) * paragraphGap
  }

  static func height(ofCode code: String) -> CGFloat {
    CGFloat(code.reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }) * 17 + 20
  }

  private static func characterCount(_ block: MarkdownBlock) -> Int {
    switch block {
    case let .paragraph(text), let .heading(_, text): text.plainText.count
    case let .bulletList(items): items.reduce(0) { $0 + $1.plainText.count + 40 }
    case let .orderedList(items): items.reduce(0) { $0 + $1.text.plainText.count + 40 }
    case let .list(list): list.items.reduce(0) { $0 + $1.blocks.reduce(40) { $0 + characterCount($1) } }
    case let .blockQuote(blocks): blocks.reduce(0) { $0 + characterCount($1) }
    case let .codeBlock(_, code, _): code.count
    case .table, .thematicBreak: 40
    }
  }
}
