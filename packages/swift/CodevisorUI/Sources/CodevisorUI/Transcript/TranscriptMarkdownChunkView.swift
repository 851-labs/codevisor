import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Shared renderer for a projected Markdown row on macOS and iOS.
public struct TranscriptMarkdownChunkView: View {
    private let chunk: TranscriptMarkdownChunk
    private let streamID: String
    @Environment(\.markdownTheme) private var markdownTheme

    public init(chunk: TranscriptMarkdownChunk, streamID: String) {
        self.chunk = chunk
        self.streamID = streamID
    }

    @ViewBuilder
    public var body: some View {
        let animationGroupID = "\(chunk.messageID.uuidString):\(chunk.sourceID)"
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
        .environment(\.markdownTheme, resolvedMarkdownTheme)
    }

    private var resolvedMarkdownTheme: MarkdownTheme {
        guard chunk.container == .assistantWorked else { return markdownTheme }
        var resolved = markdownTheme
        resolved.textForeground = markdownTheme.secondaryTextForeground
        resolved.codeForeground = markdownTheme.secondaryTextForeground
        return resolved
    }
}
