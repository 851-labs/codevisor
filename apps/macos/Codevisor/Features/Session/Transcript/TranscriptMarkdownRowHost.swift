import AppKit
import CodevisorUI
import MarkdownCore
import StreamMarkdown
import TranscriptKit

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
    installVerticalClipMask()
    addSubview(decoration)
    addSubview(markdownView)
    markdownView.onContentHeightChange = { [weak self] in
      self?.requestContentMeasurement()
    }
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setContent(
    _ chunk: TranscriptMarkdownChunk,
    streamID: String,
    style: TranscriptMarkdownRowStyle,
    linkAction: MarkdownLinkAction?,
    imageLoader: MarkdownImageLoader = .remote,
    knownHeight: CGFloat?
  ) {
    self.chunk = chunk
    self.style = style
    decoration.frame = bounds
    decoration.setContent(chunk, style: style)
    markdownView.tableBleedLimit =
      chunk.container == .planDocument
      ? PlanDocumentMetrics.tableBleedLimit
      : .greatestFiniteMagnitude
    markdownView.setContent(
      blocks: chunk.blocks,
      theme: style.markdown,
      streamID: streamID,
      linkAction: linkAction,
      imageLoader: imageLoader
    )
    measuredWidth = max(1, bounds.width)
    reportedHeight = knownHeight
    measureAndLayout()
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
    let becameReady = !presentationReady && markdownView.isContentReady
    reportedHeight = height
    presentationReady = markdownView.isContentReady
    markdownView.frame = NSRect(
      x: geometry.contentFrame.minX,
      y: geometry.topInset,
      width: geometry.contentFrame.width,
      height: contentHeight
    )
    if becameReady || previouslyReportedHeight.map({ abs($0 - height) > 0.5 }) ?? true {
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
    Self.contentGeometry(for: chunk, style: style, rowWidth: bounds.width)
  }

  static func contentGeometry(
    for chunk: TranscriptMarkdownChunk,
    style: TranscriptMarkdownRowStyle,
    rowWidth: CGFloat
  ) -> (contentFrame: NSRect, topInset: CGFloat, bottomInset: CGFloat) {
    let fragmentIndent =
      chunk.fragment.map {
        CGFloat($0.quoteDepth) * MarkdownFragmentMetrics.quoteIndent
          + CGFloat($0.listDepth) * MarkdownFragmentMetrics.listIndent
      } ?? 0
    let planInset =
      chunk.container == .planDocument
      ? TranscriptMarkdownRowLayout.planHorizontalInset
      : 0
    let timeline = chunk.timeline
    let linePadding = TranscriptTimelineMarks.linePadding
    let topInset =
      chunk.topSpacing(in: style.markdown) + (timeline?.startsLine == true ? linePadding : 0)
    let fragmentSpacing = chunk.fragment.map { style.markdown.gap($0.trailingSpacing) } ?? 0
    let planBottom =
      chunk.container == .planDocument && chunk.isLastInDocument
      ? TranscriptMarkdownRowLayout.planBottomInset
      : 0
    let timelineBottom = timeline?.endsLine == true ? linePadding : 0
    let leading = planInset + fragmentIndent + (timeline == nil ? 0 : TranscriptTimelineMarks.gutterWidth)
    return (
      NSRect(
        x: leading,
        y: 0,
        width: max(1, rowWidth - leading - planInset),
        height: 1
      ),
      topInset,
      fragmentSpacing + planBottom + timelineBottom
    )
  }
}
