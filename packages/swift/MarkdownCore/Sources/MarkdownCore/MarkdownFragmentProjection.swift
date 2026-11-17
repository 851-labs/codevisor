import CoreGraphics

public enum MarkdownFragmentProjection {
  public static let maximumEstimatedTextFragmentHeight: CGFloat = 320
  public static let maximumTextBlocksPerFragment = 12
  public static let estimatedBlockSpacing: CGFloat = 13

  public static func fragments(from blocks: [MarkdownBlock]) -> [MarkdownFragment] {
    var fragments = topLevelFragments(of: blocks)
    for index in fragments.indices where fragments[index].startsSourceBlock {
      let first = fragments[index].firstOrdinal
      fragments[index].precedingRole = first > 0 ? blocks[first - 1].role : nil
    }
    return fragments
  }

  public static func isTextBlock(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .heading, .paragraph, .bulletList, .orderedList: true
    case .list, .blockQuote: rendersInPlace(block)
    case .codeBlock, .table, .thematicBreak: false
    }
  }

  public static func nestsFragmentBlocks(_ blocks: [MarkdownBlock]) -> Bool {
    blocks.contains(where: needsOwnFragment)
  }

  public static func estimatedHeight(for blocks: [MarkdownBlock]) -> CGFloat {
    blocks.reduce(0) { $0 + estimatedHeight(for: $1) }
      + CGFloat(max(0, blocks.count - 1)) * estimatedBlockSpacing
  }

  public static func estimatedHeight(for blocks: [MarkdownBlock], layout: MarkdownFragmentLayout?) -> CGFloat {
    let content = estimatedHeight(for: blocks)
    guard let layout else { return content }
    switch layout.trailingSpacing {
    case .none: return content
    case .block: return content + estimatedBlockSpacing
    case .listItem: return content + 6
    }
  }

  public static func estimatedHeight(for block: MarkdownBlock) -> CGFloat {
    switch block {
    case let .heading(_, text), let .paragraph(text):
      max(24, min(360, 24 + CGFloat(text.characterCount / 72) * 20))
    case let .codeBlock(_, code, _):
      max(80, min(640, 52 + CGFloat(code.split(separator: "\n").count) * 18))
    case let .bulletList(items):
      max(28, CGFloat(items.count) * 26)
    case let .orderedList(items):
      max(28, CGFloat(items.count) * 26)
    case let .list(list):
      max(32, CGFloat(list.items.count) * 30)
    case let .blockQuote(blocks):
      max(36, CGFloat(blocks.count) * 34)
    case let .table(_, _, body):
      max(72, CGFloat(body.count + 1) * 34)
    case .thematicBreak:
      1
    }
  }

  static func rendersInPlace(_ block: MarkdownBlock) -> Bool {
    switch block {
    case let .list(list): !nestsFragmentBlocks(list.items.flatMap(\.blocks))
    case let .blockQuote(blocks): !nestsFragmentBlocks(blocks)
    default: true
    }
  }

  static func needsOwnFragment(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .codeBlock, .table, .thematicBreak: true
    case .list, .blockQuote: !rendersInPlace(block)
    case .heading, .paragraph, .bulletList, .orderedList: false
    }
  }

  static func fitsInTextFragment(_ blocks: [MarkdownBlock]) -> Bool {
    blocks.count <= maximumTextBlocksPerFragment
      && estimatedHeight(for: blocks) <= maximumEstimatedTextFragmentHeight
  }

  private static func topLevelFragments(of blocks: [MarkdownBlock]) -> [MarkdownFragment] {
    var fragments: [MarkdownFragment] = []
    var text = TextRun()
    for (ordinal, block) in blocks.enumerated() {
      if isTextBlock(block) {
        if !text.accepts(block) { text.flush(into: &fragments) }
        text.append(block, at: ordinal)
        continue
      }
      text.flush(into: &fragments)
      fragments += standaloneFragments(of: block, at: ordinal)
    }
    text.flush(into: &fragments)
    return fragments
  }

  private static func standaloneFragments(of block: MarkdownBlock, at ordinal: Int) -> [MarkdownFragment] {
    switch block {
    case let .blockQuote(quoted) where !rendersInPlace(block):
      MarkdownStructuralFragments.fragments(from: quoted, ordinal: ordinal, quoteListDepths: [0], path: "q")
    case .list where !rendersInPlace(block):
      MarkdownStructuralFragments.fragments(from: [block], ordinal: ordinal, quoteListDepths: [], path: "l")
    default:
      [MarkdownFragment(blocks: [block], firstOrdinal: ordinal)]
    }
  }

  private struct TextRun {
    var blocks: [MarkdownBlock] = []
    var start = 0

    func accepts(_ block: MarkdownBlock) -> Bool {
      blocks.isEmpty || fitsInTextFragment(blocks + [block])
    }

    mutating func append(_ block: MarkdownBlock, at ordinal: Int) {
      if blocks.isEmpty { start = ordinal }
      blocks.append(block)
    }

    mutating func flush(into fragments: inout [MarkdownFragment]) {
      guard !blocks.isEmpty else { return }

      fragments.append(MarkdownFragment(blocks: blocks, firstOrdinal: start))
      blocks.removeAll(keepingCapacity: true)
    }
  }
}
