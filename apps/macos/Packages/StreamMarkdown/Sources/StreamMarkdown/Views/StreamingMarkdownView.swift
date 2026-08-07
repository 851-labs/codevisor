import SwiftUI

/// One SwiftUI identity's claim on a semantic text stream. A baseline lasts
/// for exactly the first rendered pass, long enough for every native Markdown
/// surface to seed its word reconciler, and then switches to normal live mode.
@MainActor
private final class StreamingMarkdownAnimationMount {
    struct Resolution {
        let animatesInitialContent: Bool
        let activationToken: Int
        let needsActivation: Bool
    }

    private var hasResolved = false
    private var streamID: String?
    private var presentationID: ObjectIdentifier?
    private var isBaselining = false
    private var activationToken = 0

    func resolve(
        streamID: String?,
        presentation: StreamingTextAnimationPresentation?
    ) -> Resolution {
        let nextPresentationID = presentation.map(ObjectIdentifier.init)
        if !hasResolved || self.streamID != streamID || presentationID != nextPresentationID {
            hasResolved = true
            self.streamID = streamID
            presentationID = nextPresentationID
            if let streamID, let presentation {
                isBaselining = !presentation.claimInitialAnimation(for: streamID)
            } else {
                // Standalone callers retain the original behavior: an
                // incomplete view animates the text it is first given.
                isBaselining = false
            }
            if isBaselining { activationToken &+= 1 }
        }
        return Resolution(
            animatesInitialContent: !isBaselining,
            activationToken: activationToken,
            needsActivation: isBaselining
        )
    }

    func activate(token: Int) -> Bool {
        guard isBaselining, token == activationToken else { return false }
        isBaselining = false
        return true
    }
}

/// Renders markdown text, re-parsing on change so streamed responses display
/// incrementally. Blocks render in document order, including tool output and
/// partially-arrived code fences.
///
/// Pass `isComplete: false` while the text is still streaming: the segmenter
/// then re-parses only the unsettled tail per flush and renders each block as
/// its own segment, so per-flush work scales with the growing block instead
/// of the whole document. When the flag flips back to true the segments merge
/// into selectable runs again (one full re-render at finalize). The default
/// (`true`) is right for any text that arrives whole.
public struct StreamingMarkdownView: View {
    private let text: String
    private let isComplete: Bool
    private let foregroundColor: Color?
    private let streamID: String?
    private let animationPresentation: StreamingTextAnimationPresentation?
    @Environment(\.markdownTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Per-view-identity incremental state (see `StreamingSegmenter`). A
    /// plain non-observable class held in `@State`: `body` runs far more
    /// often than the text changes (theme changes, sibling observable churn,
    /// the per-frame re-renders of a streaming transcript), and it must
    /// persist across body evaluations without cache writes re-rendering the
    /// view. Fresh identities fall through to the process-level
    /// `MarkdownSegmentCache`.
    @State private var segmenter = StreamingSegmenter()
    /// Message-wide visual cadence. Individual native text surfaces retain
    /// their own word identities but draw start times from this one queue.
    @State private var animationTimeline = StreamingTextAnimationTimeline()
    @State private var hasActiveEntranceAnimation = false
    /// Separates a semantic stream's first live appearance from a native view
    /// remount. The companion revision is only an invalidation signal after a
    /// one-pass baseline; the mount object itself remains non-observable.
    @State private var animationMount = StreamingMarkdownAnimationMount()
    @State private var animationMountRevision = 0

    public init(
        _ text: String,
        isComplete: Bool = true,
        foregroundColor: Color? = nil,
        streamID: String? = nil,
        animationPresentation: StreamingTextAnimationPresentation? = nil
    ) {
        self.text = text
        self.isComplete = isComplete
        self.foregroundColor = foregroundColor
        self.streamID = streamID
        self.animationPresentation = animationPresentation
    }

    public var body: some View {
        let mount = animationMount.resolve(
            streamID: streamID,
            presentation: animationPresentation
        )
        let _ = animationMountRevision
        MarkdownSegmentListView(
            segments: segmenter.segments(for: text, isComplete: isComplete),
            foregroundColor: foregroundColor ?? theme.textForeground,
            animationTimeline: isComplete ? nil : animationTimeline,
            animatesInitialContent: mount.animatesInitialContent,
            documentSource: text,
            // A reused SwiftUI/native surface must reset its word reconciler
            // when the semantic transcript entry changes.
            animationPath: streamID.map { "stream.\($0).root" } ?? "root",
            reduceMotion: reduceMotion
        )
        .preference(
            key: StreamingMarkdownEntranceAnimationPreferenceKey.self,
            value: hasActiveEntranceAnimation
        )
        .onAppear {
            animationTimeline.observeActivity { active in
                hasActiveEntranceAnimation = active
            }
        }
        .onDisappear {
            animationTimeline.observeActivity(nil)
            hasActiveEntranceAnimation = false
        }
        .onChange(of: isComplete, initial: true) { _, complete in
            if complete { animationTimeline.reset() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { animationTimeline.reset() }
        }
        .task(id: mount.activationToken) {
            guard mount.needsActivation else { return }
            // The first native surfaces must consume the baseline before the
            // same semantic stream becomes eligible for later append fades.
            await Task.yield()
            if animationMount.activate(token: mount.activationToken) {
                animationMountRevision &+= 1
            }
        }
    }
}

/// Aggregates the entrance-animation state of every streamed Markdown surface
/// beneath a transcript row. Multiple commentary blocks can animate at once,
/// so preference reduction is an OR rather than last-writer-wins.
public struct StreamingMarkdownEntranceAnimationPreferenceKey: PreferenceKey {
    public static let defaultValue = false

    public static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// Renders markdown blocks as segments: consecutive text-like blocks merge
/// into a single selectable TextKit storage so selection can span multiple
/// lines and blocks, while code blocks, tables, quotes, and rules keep their
/// own views.
struct MarkdownSegmentsView: View {
    let blocks: [MarkdownBlock]
    let foregroundColor: Color
    var animationTimeline: StreamingTextAnimationTimeline?
    var animatesInitialContent = true
    var documentSource = ""
    var animationPath = "nested"
    var reduceMotion = false

    var body: some View {
        MarkdownSegmentListView(
            segments: MarkdownSegment.segments(from: blocks),
            foregroundColor: foregroundColor,
            animationTimeline: animationTimeline,
            animatesInitialContent: animatesInitialContent,
            documentSource: documentSource,
            animationPath: animationPath,
            reduceMotion: reduceMotion
        )
    }
}

/// Renders pre-computed markdown segments in document order.
struct MarkdownSegmentListView: View {
    let segments: [MarkdownSegment]
    let foregroundColor: Color
    let animationTimeline: StreamingTextAnimationTimeline?
    let animatesInitialContent: Bool
    let documentSource: String
    let animationPath: String
    let reduceMotion: Bool
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.blockSpacing) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                MarkdownSegmentView(
                    segment: segment,
                    foregroundColor: foregroundColor,
                    animationTimeline: animationTimeline,
                    animationEnabled: animationTimeline != nil,
                    animatesInitialContent: animatesInitialContent,
                    documentSource: documentSource,
                    animationPath: "\(animationPath).\(index)",
                    reduceMotion: reduceMotion
                )
                    .equatable()
            }
        }
    }
}

/// A settled streaming segment is an explicit SwiftUI equality boundary.
/// Growing the hosting surface still lays out the stack, but it cannot rebuild
/// or repaint the already-rendered prefix; only the changing tail crosses this
/// boundary. `StreamingSegmenter` preserves the values of settled segments,
/// making the comparison O(1) in the steady state.
private struct MarkdownSegmentView: View, Equatable {
    let segment: MarkdownSegment
    let foregroundColor: Color
    let animationTimeline: StreamingTextAnimationTimeline?
    let animationEnabled: Bool
    let animatesInitialContent: Bool
    let documentSource: String
    let animationPath: String
    let reduceMotion: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segment == rhs.segment
            && lhs.foregroundColor == rhs.foregroundColor
            && lhs.animationEnabled == rhs.animationEnabled
            && lhs.animatesInitialContent == rhs.animatesInitialContent
            && lhs.animationPath == rhs.animationPath
            && lhs.reduceMotion == rhs.reduceMotion
    }

    var body: some View {
        switch segment {
        case let .textRun(runBlocks):
            #if canImport(AppKit) || canImport(UIKit)
            MarkdownTextRunView(
                blocks: runBlocks,
                foregroundColor: foregroundColor,
                animationContext: animationTimeline.map {
                    StreamingTextAnimationContext(
                        timeline: $0,
                        sourceID: animationPath,
                        documentSource: documentSource,
                        isStreaming: true,
                        animatesInitialContent: animatesInitialContent,
                        reduceMotion: reduceMotion
                    )
                }
            )
            #else
            MarkdownPortableTextRunView(blocks: runBlocks, foregroundColor: foregroundColor)
            #endif
        case let .block(block):
            MarkdownBlockView(
                block: block,
                foregroundColor: foregroundColor,
                animationTimeline: animationTimeline,
                animatesInitialContent: animatesInitialContent,
                documentSource: documentSource,
                animationPath: animationPath,
                reduceMotion: reduceMotion
            )
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
    var animationPath = "block"
    var reduceMotion = false
    @Environment(\.markdownTheme) private var theme

    var body: some View {
        switch block {
        case .heading, .paragraph, .bulletList, .orderedList:
            // Normally coalesced into a MarkdownTextRunView by
            // MarkdownSegmentsView; render standalone blocks the same way so
            // they stay selectable.
            #if canImport(AppKit) || canImport(UIKit)
            MarkdownTextRunView(
                blocks: [block],
                foregroundColor: foregroundColor,
                animationContext: animationTimeline.map {
                    StreamingTextAnimationContext(
                        timeline: $0,
                        sourceID: animationPath,
                        documentSource: documentSource,
                        isStreaming: true,
                        animatesInitialContent: animatesInitialContent,
                        reduceMotion: reduceMotion
                    )
                }
            )
            #else
            MarkdownPortableTextRunView(blocks: [block], foregroundColor: foregroundColor)
            #endif

        case let .codeBlock(language, code, isComplete):
            CodeBlockView(language: language, code: code, isComplete: isComplete)

        case let .blockQuote(blocks):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.quoteBarColor)
                    .frame(width: 3)
                MarkdownSegmentsView(
                    blocks: blocks,
                    foregroundColor: foregroundColor,
                    animationTimeline: animationTimeline,
                    animatesInitialContent: animatesInitialContent,
                    documentSource: documentSource,
                    animationPath: "\(animationPath).quote",
                    reduceMotion: reduceMotion
                )
            }
            .fixedSize(horizontal: false, vertical: true)

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
}

#Preview("Rich document") {
    ScrollView {
        StreamingMarkdownView("""
        # Heading One

        A paragraph with **bold**, *italic*, and `inline code`.

        - First bullet
        - Second bullet

        1. Step one
        2. Step two

        > A thoughtful quote.

        | Name | Role |
        | :--- | ---: |
        | Ann  | Lead |

        ```swift
        let greeting = "Hello"
        print(greeting)
        ```

        ---
        Done.
        """)
        .padding()
    }
    .frame(width: 460, height: 640)
}

#Preview("Streaming (incomplete fence)") {
    StreamingMarkdownView("""
    Here is some code being written:

    ```swift
    func work() {
        let value = 4
    """)
    .padding()
    .frame(width: 420)
}
