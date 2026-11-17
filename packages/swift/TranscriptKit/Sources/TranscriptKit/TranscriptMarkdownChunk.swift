import Foundation
import MarkdownCore

public struct TranscriptMarkdownChunk: Sendable, Equatable {
  public let messageID: UUID
  public let sourceID: String
  public let animationSourceID: String
  public let ordinal: Int
  public let content: MarkdownFragment
  public let documentSource: String
  public let lifecycle: TranscriptBlockLifecycle
  public let container: TranscriptMarkdownContainer
  public let documentBlockCount: Int
  public let timeline: TranscriptTimelineMarks?

  public init(
    messageID: UUID,
    sourceID: String,
    ordinal: Int,
    content: MarkdownFragment,
    documentSource: String,
    lifecycle: TranscriptBlockLifecycle,
    container: TranscriptMarkdownContainer,
    animationSourceID: String? = nil,
    documentBlockCount: Int = 0,
    timeline: TranscriptTimelineMarks? = nil
  ) {
    self.messageID = messageID
    self.sourceID = sourceID
    self.animationSourceID = animationSourceID ?? sourceID
    self.ordinal = ordinal
    self.content = content
    self.documentSource = documentSource
    self.lifecycle = lifecycle
    self.container = container
    self.documentBlockCount = documentBlockCount
    self.timeline = timeline
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.messageID == rhs.messageID && lhs.sourceID == rhs.sourceID
      && lhs.animationSourceID == rhs.animationSourceID
      && lhs.ordinal == rhs.ordinal && lhs.content == rhs.content
      && lhs.lifecycle == rhs.lifecycle && lhs.container == rhs.container
      && lhs.documentBlockCount == rhs.documentBlockCount && lhs.timeline == rhs.timeline
  }

  public var blocks: [MarkdownBlock] { content.blocks }

  public var fragment: MarkdownFragmentLayout? { content.layout }

  public var precedingRole: MarkdownBlockRole? { content.precedingRole }

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
    MarkdownFragmentProjection.estimatedHeight(for: blocks, layout: fragment)
      + (precedingRole == nil ? 0 : MarkdownFragmentProjection.estimatedBlockSpacing)
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
