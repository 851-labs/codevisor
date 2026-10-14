import StreamMarkdown
import SwiftUI
import TranscriptKit

public struct TranscriptMarkdownChunkView: View {
  private let chunk: TranscriptMarkdownChunk
  @Environment(\.attachmentImages) private var attachmentImages
  @Environment(\.markdownTheme) private var markdownTheme

  public init(chunk: TranscriptMarkdownChunk) {
    self.chunk = chunk
  }

  @ViewBuilder
  public var body: some View {
    let animationGroupID = chunk.animationGroupID
    let streamID = chunk.animationStreamID
    Group {
      if chunk.container == .planDocument {
        PlanDocumentBlockView(
          blocks: chunk.blocks,
          documentSource: chunk.documentSource,
          streamID: streamID,
          animationGroupID: animationGroupID,
          isStreaming: chunk.lifecycle == .receiving,
          isLast: chunk.isLastInDocument,
          fragmentLayout: chunk.fragment,
          topSpacing: topSpacing
        )
      } else if let fragment = chunk.fragment {
        MarkdownFragmentRenderView(
          blocks: chunk.blocks,
          documentSource: chunk.documentSource,
          streamID: streamID,
          animationGroupID: animationGroupID,
          isStreaming: chunk.lifecycle == .receiving,
          layout: fragment
        )
        .padding(.top, topSpacing)
      } else {
        MarkdownBlockRenderView(
          blocks: chunk.blocks,
          documentSource: chunk.documentSource,
          streamID: streamID,
          animationGroupID: animationGroupID,
          isStreaming: chunk.lifecycle == .receiving
        )
        .padding(.top, topSpacing)
      }
    }
    .environment(\.markdownImageLoader, attachmentImages?.markdownImageLoader ?? .remote)
    .modifier(WorkedTimelineGutter(marks: chunk.timeline))
  }

  private var topSpacing: CGFloat { chunk.topSpacing(in: markdownTheme) }
}

public extension TranscriptMarkdownChunk {
  func topSpacing(in theme: MarkdownTheme) -> CGFloat {
    precedingRole.map { theme.blockGap(after: $0, before: blocks[0].role) } ?? 0
  }
}
