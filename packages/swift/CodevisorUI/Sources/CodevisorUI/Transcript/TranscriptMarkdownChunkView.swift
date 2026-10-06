import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Shared renderer for a projected Markdown row on macOS and iOS.
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
  }

  private var topSpacing: CGFloat { chunk.topSpacing(in: markdownTheme) }
}

public extension TranscriptMarkdownChunk {
  /// The gap above a row that starts a new block of its document, shared
  /// by the SwiftUI and native AppKit row renderers.
  func topSpacing(in theme: MarkdownTheme) -> CGFloat {
    precedingRole.map { theme.blockGap(after: $0, before: blocks[0].role) } ?? 0
  }
}
