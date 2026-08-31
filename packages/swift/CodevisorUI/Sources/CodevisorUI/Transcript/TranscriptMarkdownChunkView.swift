import StreamMarkdown
import SwiftUI
import TranscriptKit

/// Shared renderer for a projected Markdown row on macOS and iOS.
public struct TranscriptMarkdownChunkView: View {
    private let chunk: TranscriptMarkdownChunk
    private let streamID: String

    public init(chunk: TranscriptMarkdownChunk, streamID: String) {
        self.chunk = chunk
        self.streamID = streamID
    }

    @ViewBuilder
    public var body: some View {
        if chunk.container == .planDocument {
            PlanDocumentBlockView(
                blocks: chunk.blocks,
                documentSource: chunk.documentSource,
                streamID: streamID,
                isStreaming: chunk.lifecycle == .receiving,
                isFirst: chunk.isFirstInDocument,
                isLast: chunk.isLastInDocument,
                fragmentLayout: fragmentLayout
            )
        } else if let fragmentLayout {
            MarkdownFragmentRenderView(
                blocks: chunk.blocks,
                documentSource: chunk.documentSource,
                streamID: streamID,
                isStreaming: chunk.lifecycle == .receiving,
                layout: fragmentLayout
            )
        } else {
            MarkdownBlockRenderView(
                blocks: chunk.blocks,
                documentSource: chunk.documentSource,
                streamID: streamID,
                isStreaming: chunk.lifecycle == .receiving
            )
        }
    }

    private var fragmentLayout: MarkdownFragmentLayout? {
        chunk.fragment.map { fragment in
            let trailingSpacing: MarkdownFragmentLayout.TrailingSpacing
            switch fragment.trailingSpacing {
            case .none: trailingSpacing = .none
            case .block: trailingSpacing = .block
            case .listItem: trailingSpacing = .listItem
            }
            return MarkdownFragmentLayout(
                quoteDepth: fragment.quoteDepth,
                listDepth: fragment.listDepth,
                listMarkers: fragment.listMarkers.map {
                    MarkdownFragmentLayout.ListMarker(depth: $0.depth, text: $0.text)
                },
                trailingSpacing: trailingSpacing
            )
        }
    }
}
