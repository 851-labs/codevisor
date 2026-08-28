import SwiftUI

/// Renders one already-parsed Markdown block. TranscriptKit uses this surface
/// when each block is independently mounted by the native transcript
/// virtualizer, avoiding a second parse inside the visible row.
public struct MarkdownBlockRenderView: View {
    private let block: MarkdownBlock
    private let foregroundColor: Color?
    private let documentSource: String
    private let streamID: String
    private let isStreaming: Bool
    @Environment(\.markdownTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animationTimeline = StreamingTextAnimationTimeline()

    public init(
        block: MarkdownBlock,
        foregroundColor: Color? = nil,
        documentSource: String = "",
        streamID: String,
        isStreaming: Bool
    ) {
        self.block = block
        self.foregroundColor = foregroundColor
        self.documentSource = documentSource
        self.streamID = streamID
        self.isStreaming = isStreaming
    }

    public var body: some View {
        MarkdownBlockView(
            block: block,
            foregroundColor: foregroundColor ?? theme.textForeground,
            animationTimeline: isStreaming && !reduceMotion ? animationTimeline : nil,
            documentSource: documentSource,
            pacingSourceID: streamID,
            animationPath: streamID,
            reduceMotion: reduceMotion
        )
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { animationTimeline.reset() }
        }
    }
}
