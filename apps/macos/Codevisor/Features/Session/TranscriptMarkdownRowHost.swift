import AppKit
import StreamMarkdown
import TranscriptKit

/// Direct AppKit host for one immutable Markdown projection row.
///
/// Unlike ``TranscriptRowHost``, this view owns no hosting controller and
/// never asks SwiftUI for an intrinsic size. Text, code, and tables are laid
/// out by StreamMarkdown's native settled renderer.
@MainActor
final class TranscriptMarkdownRowHost: TranscriptMountedRowHost {
    private let decoration = TranscriptMarkdownRowDecoration()
    private let markdownView = SettledMarkdownView()
    private var chunk: TranscriptMarkdownChunk?
    private var style: TranscriptMarkdownRowStyle?
    private var measuredWidth: CGFloat = -1
    private var reportedHeight: CGFloat?
    private var presentationReady = false

    override var isFlipped: Bool { true }
    override var isPresentationReady: Bool { presentationReady }
    override var needsRunwayPreparation: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        addSubview(decoration)
        addSubview(markdownView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(
        _ chunk: TranscriptMarkdownChunk,
        streamID: String,
        style: TranscriptMarkdownRowStyle,
        knownHeight: CGFloat?
    ) {
        var resolvedStyle = style
        if chunk.container == .assistantWorked {
            resolvedStyle.markdown.textForeground = style.markdown.secondaryTextForeground
            resolvedStyle.markdown.codeForeground = style.markdown.secondaryTextForeground
        }
        self.chunk = chunk
        self.style = resolvedStyle
        decoration.frame = bounds
        decoration.setContent(chunk, style: resolvedStyle)
        markdownView.setContent(
            blocks: chunk.blocks,
            theme: resolvedStyle.markdown,
            streamID: streamID,
            linkAction: nil
        )
        measuredWidth = knownHeight == nil ? -1 : max(1, bounds.width)
        reportedHeight = knownHeight
        presentationReady = knownHeight != nil
        layoutMarkdown(usingKnownHeight: knownHeight)
        if knownHeight == nil { measureAndLayout() }
    }

    override func prepareForMountedRow() {
        layer?.removeAllAnimations()
        layer?.opacity = 1
        presentationReady = false
    }

    @discardableResult
    override func syncContentWidth() -> Bool {
        let width = max(1, bounds.width)
        guard abs(width - measuredWidth) > 0.25 else { return false }
        measuredWidth = width
        measureAndLayout()
        return true
    }

    override func prepareForImmediatePresentation() {
        if !presentationReady { measureAndLayout() }
        layoutSubtreeIfNeeded()
    }

    override func requestContentMeasurement(forceReport: Bool = true) {
        measuredWidth = -1
        if forceReport { reportedHeight = nil }
        _ = syncContentWidth()
    }

    override func layout() {
        super.layout()
        decoration.frame = bounds
        if abs(max(1, bounds.width) - measuredWidth) > 0.25 {
            _ = syncContentWidth()
        } else {
            layoutMarkdown(usingKnownHeight: reportedHeight)
        }
    }

    private func measureAndLayout() {
        guard let chunk, let style else { return }
        let geometry = contentGeometry(for: chunk, style: style)
        let contentHeight = markdownView.contentHeight(forWidth: geometry.contentFrame.width)
        let height = ceil(geometry.topInset + contentHeight + geometry.bottomInset)
        let previouslyReportedHeight = reportedHeight
        reportedHeight = height
        presentationReady = true
        markdownView.frame = NSRect(
            x: geometry.contentFrame.minX,
            y: geometry.topInset,
            width: geometry.contentFrame.width,
            height: contentHeight
        )
        // The outer frame initially contains an estimate. Even when that
        // estimate happens to equal the measured result (for example, a 1pt
        // separator), the first native measurement must still enter the
        // authoritative ledger so the initial-presentation gate can resolve.
        if previouslyReportedHeight.map({ abs($0 - height) > 0.5 }) ?? true {
            onHeightChange?(height)
        }
    }

    private func layoutMarkdown(usingKnownHeight knownHeight: CGFloat?) {
        guard let chunk, let style, let knownHeight else { return }
        let geometry = contentGeometry(for: chunk, style: style)
        markdownView.frame = NSRect(
            x: geometry.contentFrame.minX,
            y: geometry.topInset,
            width: geometry.contentFrame.width,
            height: max(1, knownHeight - geometry.topInset - geometry.bottomInset)
        )
    }

    private func contentGeometry(
        for chunk: TranscriptMarkdownChunk,
        style: TranscriptMarkdownRowStyle
    ) -> (contentFrame: NSRect, topInset: CGFloat, bottomInset: CGFloat) {
        let fragmentIndent =
            chunk.fragment.map {
                CGFloat($0.quoteDepth) * TranscriptMarkdownRowLayout.quoteIndent
                    + CGFloat($0.listDepth) * TranscriptMarkdownRowLayout.listIndent
            } ?? 0
        let planInset =
            chunk.container == .planDocument
            ? TranscriptMarkdownRowLayout.planHorizontalInset
            : 0
        let topInset =
            chunk.container == .planDocument
                && chunk.fragment == nil
                && !chunk.isFirstInDocument
            ? style.markdown.blockSpacing
            : 0
        let fragmentSpacing: CGFloat =
            switch chunk.fragment?.trailingSpacing {
            case .block: style.markdown.blockSpacing
            case .listItem: style.markdown.listItemSpacing
            case .some(.none), nil: 0
            }
        let planBottom =
            chunk.container == .planDocument && chunk.isLastInDocument
            ? TranscriptMarkdownRowLayout.planBottomInset
            : 0
        let leading = planInset + fragmentIndent
        return (
            NSRect(
                x: leading,
                y: 0,
                width: max(1, bounds.width - leading - planInset),
                height: 1
            ),
            topInset,
            fragmentSpacing + planBottom
        )
    }
}
