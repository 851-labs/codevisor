import SwiftUI

/// Renders one already-parsed Markdown row. Consecutive text-like blocks can
/// share one TextKit surface so transcript chunking avoids both extra native
/// hosts and extra text layout passes.
public struct MarkdownBlockRenderView: View {
    private let blocks: [MarkdownBlock]
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
        blocks = [block]
        self.foregroundColor = foregroundColor
        self.documentSource = documentSource
        self.streamID = streamID
        self.isStreaming = isStreaming
    }

    public init(
        blocks: [MarkdownBlock],
        foregroundColor: Color? = nil,
        documentSource: String = "",
        streamID: String,
        isStreaming: Bool
    ) {
        precondition(!blocks.isEmpty, "Markdown rows must contain at least one block")
        self.blocks = blocks
        self.foregroundColor = foregroundColor
        self.documentSource = documentSource
        self.streamID = streamID
        self.isStreaming = isStreaming
    }

    @ViewBuilder
    public var body: some View {
        Group {
            if blocks.count > 1, blocks.allSatisfy(\.isTextRunCompatible) {
                #if canImport(AppKit) || canImport(UIKit)
                    MarkdownTextRunView(
                        blocks: blocks,
                        foregroundColor: foregroundColor ?? theme.textForeground,
                        animationContext: animationContext
                    )
                #else
                    blockStack
                #endif
            } else if blocks.count == 1, let block = blocks.first {
                MarkdownBlockView(
                    block: block,
                    foregroundColor: foregroundColor ?? theme.textForeground,
                    animationTimeline: resolvedAnimationTimeline,
                    documentSource: documentSource,
                    pacingSourceID: streamID,
                    animationPath: streamID,
                    reduceMotion: reduceMotion
                )
            } else {
                blockStack
            }
        }
        .onChange(of: isStreaming) { _, streaming in
            if !streaming { animationTimeline.reset() }
        }
    }

    private var resolvedAnimationTimeline: StreamingTextAnimationTimeline? {
        isStreaming && !reduceMotion ? animationTimeline : nil
    }

    private var animationContext: StreamingTextAnimationContext? {
        resolvedAnimationTimeline.map {
            StreamingTextAnimationContext(
                timeline: $0,
                sourceID: streamID,
                pacingSourceID: streamID,
                documentSource: documentSource,
                isStreaming: true,
                animatesInitialContent: true,
                reduceMotion: reduceMotion
            )
        }
    }

    private var blockStack: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                MarkdownBlockView(
                    block: block,
                    foregroundColor: foregroundColor ?? theme.textForeground,
                    animationTimeline: resolvedAnimationTimeline,
                    documentSource: documentSource,
                    pacingSourceID: streamID,
                    animationPath: "\(streamID).\(index)",
                    reduceMotion: reduceMotion
                )
            }
        }
    }
}

/// Structural context for a leaf extracted from a complex block quote. The
/// decoration is deliberately an overlay: quote bars and list markers never
/// enter the Markdown leaf's native layout tree or expand its hit-testing area.
public struct MarkdownFragmentLayout: Sendable, Equatable {
    public struct ListMarker: Sendable, Equatable, Identifiable {
        public let depth: Int
        public let text: String

        public var id: Int { depth }

        public init(depth: Int, text: String) {
            self.depth = depth
            self.text = text
        }
    }

    public enum TrailingSpacing: Sendable, Equatable {
        case none
        case block
        case listItem
    }

    public let quoteDepth: Int
    public let listDepth: Int
    public let listMarkers: [ListMarker]
    public let trailingSpacing: TrailingSpacing

    public init(
        quoteDepth: Int,
        listDepth: Int,
        listMarkers: [ListMarker],
        trailingSpacing: TrailingSpacing
    ) {
        self.quoteDepth = max(0, quoteDepth)
        self.listDepth = max(0, listDepth)
        self.listMarkers = listMarkers
        self.trailingSpacing = trailingSpacing
    }
}

/// Renders one already-parsed leaf of a structurally complex quote. Each leaf
/// still uses `MarkdownBlockRenderView`, so prose remains TextKit-backed and
/// code/table leaves retain their dedicated native renderers.
public struct MarkdownFragmentRenderView: View {
    private static let quoteIndent: CGFloat = 11
    private static let listIndent: CGFloat = 24
    private static let listMarkerWidth: CGFloat = 22

    private let blocks: [MarkdownBlock]
    private let documentSource: String
    private let streamID: String
    private let isStreaming: Bool
    private let layout: MarkdownFragmentLayout
    @Environment(\.markdownTheme) private var theme

    public init(
        blocks: [MarkdownBlock],
        documentSource: String = "",
        streamID: String,
        isStreaming: Bool,
        layout: MarkdownFragmentLayout
    ) {
        precondition(!blocks.isEmpty, "Markdown fragments must contain at least one block")
        self.blocks = blocks
        self.documentSource = documentSource
        self.streamID = streamID
        self.isStreaming = isStreaming
        self.layout = layout
    }

    public var body: some View {
        MarkdownBlockRenderView(
            blocks: blocks,
            documentSource: documentSource,
            streamID: streamID,
            isStreaming: isStreaming
        )
        .padding(.leading, contentIndent)
        .padding(.bottom, trailingSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            structuralDecoration
                .allowsHitTesting(false)
        }
    }

    private var contentIndent: CGFloat {
        CGFloat(layout.quoteDepth) * Self.quoteIndent
            + CGFloat(layout.listDepth) * Self.listIndent
    }

    private var trailingSpacing: CGFloat {
        switch layout.trailingSpacing {
        case .none: 0
        case .block: theme.blockSpacing
        case .listItem: theme.listItemSpacing
        }
    }

    private var structuralDecoration: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<layout.quoteDepth, id: \.self) { depth in
                Rectangle()
                    .fill(theme.quoteBarColor)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .offset(x: CGFloat(depth) * Self.quoteIndent)
            }
            ForEach(layout.listMarkers) { marker in
                Text(marker.text)
                    .font(theme.bodyFont)
                    .foregroundStyle(theme.secondaryTextForeground)
                    .monospacedDigit()
                    .frame(width: Self.listMarkerWidth, alignment: .leading)
                    .offset(
                        x: CGFloat(layout.quoteDepth) * Self.quoteIndent
                            + CGFloat(max(0, marker.depth - 1)) * Self.listIndent
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension MarkdownBlock {
    var isTextRunCompatible: Bool {
        switch self {
        case .heading, .paragraph, .bulletList, .orderedList:
            true
        case .codeBlock, .list, .blockQuote, .table, .thematicBreak:
            false
        }
    }
}

/// Renders a single markdown block.
struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let foregroundColor: Color
    var animationTimeline: StreamingTextAnimationTimeline?
    var animatesInitialContent = true
    var documentSource = ""
    var pacingSourceID = "block"
    var animationPath = "block"
    var reduceMotion = false
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            #if canImport(AppKit) || canImport(UIKit)
                MarkdownTextRunView(
                    blocks: [block],
                    foregroundColor: foregroundColor,
                    animationContext: animationContext(path: animationPath)
                )
            #else
                MarkdownPortableTextRunView(blocks: [block], foregroundColor: foregroundColor)
            #endif

        case let .codeBlock(language, code, isComplete):
            CodeBlockView(
                id: animationPath,
                language: language,
                code: code,
                isComplete: isComplete
            )

        case let .list(list):
            #if canImport(AppKit)
                if MarkdownTextRunRenderer.canRenderFlattenedList(list) {
                    MarkdownTextRunView(
                        blocks: [block],
                        foregroundColor: foregroundColor,
                        animationContext: animationContext(path: animationPath)
                    )
                } else {
                    recursiveList(list)
                }
            #else
                recursiveList(list)
            #endif

        case let .blockQuote(blocks):
            quote(blocks)

        case let .table(headers, alignments, rows):
            #if canImport(AppKit)
                MarkdownTableView(headers: headers, alignments: alignments, rows: rows)
            #else
                MarkdownPortableTableView(headers: headers, alignments: alignments, rows: rows)
            #endif

        case .thematicBreak:
            Divider()
        }
    }

    private func animationContext(path: String) -> StreamingTextAnimationContext? {
        animationTimeline.map {
            StreamingTextAnimationContext(
                timeline: $0,
                sourceID: path,
                pacingSourceID: pacingSourceID,
                documentSource: documentSource,
                isStreaming: true,
                animatesInitialContent: animatesInitialContent,
                reduceMotion: reduceMotion
            )
        }
    }

    @ViewBuilder
    private func recursiveList(_ list: MarkdownList) -> some View {
        MarkdownRecursiveListView(
            list: list,
            foregroundColor: foregroundColor,
            animationTimeline: animationTimeline,
            animatesInitialContent: animatesInitialContent,
            documentSource: documentSource,
            pacingSourceID: pacingSourceID,
            animationPath: animationPath,
            reduceMotion: reduceMotion
        )
    }

    @ViewBuilder
    private func quote(_ blocks: [MarkdownBlock]) -> some View {
        #if canImport(AppKit)
            if MarkdownTextRunRenderer.canRenderFlattenedText(blocks) {
                MarkdownTextRunView(
                    blocks: [.blockQuote(blocks)],
                    foregroundColor: foregroundColor,
                    animationContext: animationContext(path: "\(animationPath).quote")
                )
            } else {
                quoteFallback(blocks)
            }
        #else
            quoteFallback(blocks)
        #endif
    }

    @ViewBuilder
    private func quoteFallback(_ blocks: [MarkdownBlock]) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(theme.quoteBarColor)
                .frame(width: 3)
            recursiveQuote(blocks)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func recursiveQuote(_ blocks: [MarkdownBlock]) -> some View {
        MarkdownSegmentsView(
            blocks: blocks,
            foregroundColor: foregroundColor,
            animationTimeline: animationTimeline,
            animatesInitialContent: animatesInitialContent,
            documentSource: documentSource,
            pacingSourceID: pacingSourceID,
            animationPath: "\(animationPath).quote",
            reduceMotion: reduceMotion
        )
    }
}

private struct MarkdownRecursiveListView: View {
    let list: MarkdownList
    let foregroundColor: Color
    let animationTimeline: StreamingTextAnimationTimeline?
    let animatesInitialContent: Bool
    let documentSource: String
    let pacingSourceID: String
    let animationPath: String
    let reduceMotion: Bool
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.listItemSpacing) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text(marker(for: item, at: index))
                        .foregroundStyle(theme.secondaryTextForeground)
                        .monospacedDigit()
                    MarkdownSegmentsView(
                        blocks: item.blocks,
                        foregroundColor: foregroundColor,
                        animationTimeline: animationTimeline,
                        animatesInitialContent: animatesInitialContent,
                        documentSource: documentSource,
                        pacingSourceID: pacingSourceID,
                        animationPath: "\(animationPath).item.\(index)",
                        reduceMotion: reduceMotion
                    )
                }
            }
        }
    }

    private func marker(for item: MarkdownListItem, at index: Int) -> String {
        if item.isTask { return item.isChecked ? "☑" : "☐" }
        return list.isOrdered ? "\(list.start + index)\(list.delimiter)" : "•"
    }
}
