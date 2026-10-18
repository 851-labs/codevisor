import Foundation
import MarkdownCore

public struct TranscriptTimelineMarks: Sendable, Equatable, Hashable {
  public let startsLine: Bool
  public let endsLine: Bool
  public let railAbove: Bool
  public let railBelow: Bool

  public init(startsLine: Bool, endsLine: Bool, railAbove: Bool, railBelow: Bool) {
    self.startsLine = startsLine
    self.endsLine = endsLine
    self.railAbove = railAbove
    self.railBelow = railBelow
  }

  public static let gutterWidth: CGFloat = 26
  public static let linePadding: CGFloat = 6
  public static let railWidth: CGFloat = 1.5
  public static let railX: CGFloat = 9
  public static let nodeCenterY: CGFloat = linePadding + 8
  public static let nodeClearance: CGFloat = 2.5
  public static let dotDiameter: CGFloat = 5
}

public struct TranscriptMarkdownChunk: Sendable, Equatable {
  public let messageID: UUID
  public let sourceID: String
  public let animationSourceID: String
  public let ordinal: Int
  public let blocks: [MarkdownBlock]
  public let documentSource: String
  public let lifecycle: TranscriptBlockLifecycle
  public let container: TranscriptMarkdownContainer
  public let fragment: MarkdownFragmentLayout?
  public let precedingRole: MarkdownBlockRole?
  public let documentBlockCount: Int
  public let timeline: TranscriptTimelineMarks?

  public init(
    messageID: UUID,
    sourceID: String,
    ordinal: Int,
    blocks: [MarkdownBlock],
    documentSource: String,
    lifecycle: TranscriptBlockLifecycle,
    container: TranscriptMarkdownContainer,
    animationSourceID: String? = nil,
    documentBlockCount: Int = 0,
    fragment: MarkdownFragmentLayout? = nil,
    precedingRole: MarkdownBlockRole? = nil,
    timeline: TranscriptTimelineMarks? = nil
  ) {
    precondition(!blocks.isEmpty, "Markdown chunks must contain at least one block")
    self.messageID = messageID
    self.sourceID = sourceID
    self.animationSourceID = animationSourceID ?? sourceID
    self.ordinal = ordinal
    self.blocks = blocks
    self.documentSource = documentSource
    self.lifecycle = lifecycle
    self.container = container
    self.documentBlockCount = documentBlockCount
    self.fragment = fragment
    self.precedingRole = precedingRole
    self.timeline = timeline
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.messageID == rhs.messageID && lhs.sourceID == rhs.sourceID
      && lhs.animationSourceID == rhs.animationSourceID
      && lhs.ordinal == rhs.ordinal && lhs.blocks == rhs.blocks
      && lhs.lifecycle == rhs.lifecycle && lhs.container == rhs.container
      && lhs.fragment == rhs.fragment && lhs.documentBlockCount == rhs.documentBlockCount
      && lhs.precedingRole == rhs.precedingRole && lhs.timeline == rhs.timeline
  }

  public var animationGroupID: String { "\(messageID.uuidString):\(animationSourceID)" }

  public var animationStreamID: String {
    "\(animationGroupID):\(ordinal):\(fragment?.identity ?? "text")"
  }

  public var isFirstInDocument: Bool {
    ordinal == 0 && (fragment?.isFirstInSourceBlock ?? true)
  }

  public var isLastInDocument: Bool {
    guard documentBlockCount > 0 else { return false }
    if let fragment {
      return ordinal + 1 == documentBlockCount && fragment.isLastInSourceBlock
    }
    return ordinal + blocks.count == documentBlockCount
  }

  var estimatedHeight: CGFloat {
    TranscriptMarkdownChunkProjection.estimatedHeight(
      for: blocks,
      fragment: fragment
    ) + (precedingRole == nil ? 0 : TranscriptMarkdownChunkProjection.estimatedBlockSpacing)
  }

  var measurementRevision: Int {
    var hasher = Hasher()
    for block in blocks {
      hasher.combine(block)
    }
    hasher.combine(documentBlockCount)
    hasher.combine(fragment)
    hasher.combine(precedingRole)
    hasher.combine(timeline)
    return hasher.finalize()
  }
}

enum TranscriptMarkdownChunkProjection {
  static let maximumEstimatedTextChunkHeight: CGFloat = 320
  static let maximumTextBlocksPerChunk = 12
  static let estimatedBlockSpacing: CGFloat = 13

  struct Chunk: Equatable {
    let firstOrdinal: Int
    let blocks: [MarkdownBlock]
    let fragment: MarkdownFragmentLayout?
    var precedingRole: MarkdownBlockRole?

    init(
      firstOrdinal: Int,
      blocks: [MarkdownBlock],
      fragment: MarkdownFragmentLayout? = nil
    ) {
      self.firstOrdinal = firstOrdinal
      self.blocks = blocks
      self.fragment = fragment
    }
  }

  static func chunks(from blocks: [MarkdownBlock]) -> [Chunk] {
    var chunks: [Chunk] = []
    var textBlocks: [MarkdownBlock] = []
    var textStart = 0

    func flushTextBlocks() {
      guard !textBlocks.isEmpty else { return }
      chunks.append(Chunk(firstOrdinal: textStart, blocks: textBlocks))
      textBlocks.removeAll(keepingCapacity: true)
    }

    for (ordinal, block) in blocks.enumerated() {
      if TranscriptMarkdownStructuralFragments.isTextBlock(block) {
        if shouldStartNewTextChunk(existing: textBlocks, appending: block) {
          flushTextBlocks()
        }
        if textBlocks.isEmpty { textStart = ordinal }
        textBlocks.append(block)
      } else if case let .blockQuote(quotedBlocks) = block,
        TranscriptMarkdownStructuralFragments.requiresFragmentation(quotedBlocks)
      {
        flushTextBlocks()
        chunks.append(
          contentsOf: TranscriptMarkdownStructuralFragments.chunks(
            from: quotedBlocks,
            ordinal: ordinal,
            quoteDepth: 1,
            path: "q"
          )
        )
      } else if case let .list(list) = block,
        TranscriptMarkdownStructuralFragments.requiresFragmentation(list.items.flatMap(\.blocks))
      {
        flushTextBlocks()
        chunks.append(
          contentsOf: TranscriptMarkdownStructuralFragments.chunks(
            from: [block],
            ordinal: ordinal,
            quoteDepth: 0,
            path: "l"
          )
        )
      } else {
        flushTextBlocks()
        chunks.append(Chunk(firstOrdinal: ordinal, blocks: [block]))
      }
    }
    flushTextBlocks()
    for index in chunks.indices where chunks[index].fragment?.isFirstInSourceBlock ?? true {
      let first = chunks[index].firstOrdinal
      chunks[index].precedingRole = first > 0 ? blocks[first - 1].role : nil
    }
    return chunks
  }

  static func estimatedHeight(for blocks: [MarkdownBlock]) -> CGFloat {
    blocks.reduce(0) { $0 + estimatedHeight(for: $1) }
      + CGFloat(max(0, blocks.count - 1)) * estimatedBlockSpacing
  }

  static func estimatedHeight(
    for blocks: [MarkdownBlock],
    fragment: MarkdownFragmentLayout?
  ) -> CGFloat {
    let content = estimatedHeight(for: blocks)
    guard let fragment else { return content }
    switch fragment.trailingSpacing {
    case .none: return content
    case .block: return content + estimatedBlockSpacing
    case .listItem: return content + 6
    }
  }

  static func estimatedHeight(for block: MarkdownBlock) -> CGFloat {
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

  private static func shouldStartNewTextChunk(
    existing: [MarkdownBlock],
    appending block: MarkdownBlock
  ) -> Bool {
    guard !existing.isEmpty else { return false }
    guard existing.count < maximumTextBlocksPerChunk else { return true }
    let nextHeight =
      estimatedHeight(for: existing)
      + estimatedBlockSpacing
      + estimatedHeight(for: block)
    return nextHeight > maximumEstimatedTextChunkHeight
  }

}
