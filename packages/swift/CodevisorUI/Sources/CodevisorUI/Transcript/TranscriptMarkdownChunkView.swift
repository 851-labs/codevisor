import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Shared renderer for a projected Markdown row on macOS and iOS.
public struct TranscriptMarkdownChunkView: View {
  private let chunk: TranscriptMarkdownChunk

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
          isFirst: chunk.isFirstInDocument,
          isLast: chunk.isLastInDocument,
          fragmentLayout: chunk.fragment
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
      } else {
        MarkdownBlockRenderView(
          blocks: chunk.blocks,
          documentSource: chunk.documentSource,
          streamID: streamID,
          animationGroupID: animationGroupID,
          isStreaming: chunk.lifecycle == .receiving
        )
      }
    }
  }
}
