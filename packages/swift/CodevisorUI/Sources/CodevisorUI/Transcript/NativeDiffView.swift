#if canImport(AppKit)
  import AppKit
  import StreamMarkdown
  import SwiftUI
  import TranscriptKit

  /// A complete file diff rendered by one TextKit surface. Diff rows remain
  /// ordinary text in a single storage object; the view draws gutters and row
  /// fills itself, so line count does not multiply the AppKit/SwiftUI view tree.
  struct NativeDiffView: NSViewRepresentable {
    let rows: [LineDiff.Row]
    let highlights: [Int: AttributedString]
    let theme: Theme
    let revision: String
    /// The tallest the diff shows before scrolling inside itself. Nil grows
    /// to the full diff so an enclosing scroll view owns vertical scrolling
    /// (the Review pane); transcript cards keep the bounded viewport.
    var maximumHeight: CGFloat? = DiffViewportMetrics.maximumHeight
    /// Gutter width floor, so separately rendered hunks of one file align.
    var lineNumberDigits = 2
    /// Scrolls this hunk sideways together with the rest of its file.
    var scrollSync: DiffScrollSync?

    func makeNSView(context: Context) -> NativeDiffScrollView {
      let scrollView = NativeDiffScrollView()
      scrollView.maximumHeight = maximumHeight
      scrollView.lineNumberDigits = lineNumberDigits
      scrollView.scrollSync = scrollSync
      scrollView.setContent(
        rows: rows,
        highlights: highlights,
        theme: theme,
        revision: revision
      )
      return scrollView
    }

    func updateNSView(_ scrollView: NativeDiffScrollView, context: Context) {
      scrollView.maximumHeight = maximumHeight
      scrollView.lineNumberDigits = lineNumberDigits
      scrollView.scrollSync = scrollSync
      scrollView.setContent(
        rows: rows,
        highlights: highlights,
        theme: theme,
        revision: revision
      )
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize,
      nsView scrollView: NativeDiffScrollView,
      context: Context
    ) -> CGSize? {
      let width =
        proposal.width.flatMap { $0.isFinite ? $0 : nil }
        ?? scrollView.contentFittingSize.width
      return scrollView.fitContent(toViewportWidth: max(1, width))
    }
  }

  @MainActor
  final class NativeDiffScrollView: TranscriptHorizontalScrollView {
    private(set) var diffTextView: NativeDiffTextView
    /// Line numbers and markers, pinned to the visible left edge while long
    /// lines scroll sideways beneath them.
    private let gutterView = NativeDiffGutterView()
    /// Hides code left of the pinned gutter's right edge, so scrolled text
    /// disappears under the gutter instead of showing through it.
    private let codeMask = CALayer()
    private(set) var contentFittingSize = CGSize(width: 1, height: 1)
    private var renderedRevision: String?
    private var renderedTheme: Theme?
    var maximumHeight: CGFloat? = DiffViewportMetrics.maximumHeight
    /// Gutter width floor, so separately rendered hunks of one file align.
    var lineNumberDigits = 2
    var scrollSync: DiffScrollSync? {
      didSet {
        guard scrollSync !== oldValue else { return }
        oldValue?.unregister(self)
        scrollSync?.register(self)
      }
    }
    /// Set while following the file's scroll, so the move isn't re-broadcast.
    private var isApplyingSyncedOffset = false

    override init(frame frameRect: NSRect) {
      let textStorage = NSTextStorage()
      let layoutManager = NSLayoutManager()
      textStorage.addLayoutManager(layoutManager)
      let textContainer = NSTextContainer(
        size: NSSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude
        )
      )
      textContainer.lineFragmentPadding = 0
      textContainer.widthTracksTextView = false
      textContainer.heightTracksTextView = false
      layoutManager.addTextContainer(textContainer)
      diffTextView = NativeDiffTextView(frame: .zero, textContainer: textContainer)

      super.init(frame: frameRect)
      drawsBackground = false
      borderType = .noBorder
      hasHorizontalScroller = false
      hasVerticalScroller = false
      autohidesScrollers = true
      scrollerStyle = .overlay
      horizontalScrollElasticity = .automatic
      automaticallyAdjustsContentInsets = false

      diffTextView.isEditable = false
      diffTextView.isSelectable = true
      diffTextView.isRichText = true
      diffTextView.drawsBackground = false
      diffTextView.isHorizontallyResizable = true
      diffTextView.isVerticallyResizable = true
      diffTextView.minSize = .zero
      diffTextView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      diffTextView.focusRingType = .none
      diffTextView.allowsUndo = false
      diffTextView.isContinuousSpellCheckingEnabled = false
      diffTextView.isGrammarCheckingEnabled = false
      diffTextView.isAutomaticSpellingCorrectionEnabled = false
      diffTextView.isAutomaticTextReplacementEnabled = false
      diffTextView.isAutomaticQuoteSubstitutionEnabled = false
      diffTextView.isAutomaticDashSubstitutionEnabled = false
      diffTextView.isAutomaticLinkDetectionEnabled = false
      documentView = diffTextView
      diffTextView.wantsLayer = true
      codeMask.backgroundColor = NSColor.black.cgColor
      diffTextView.layer?.mask = codeMask
      gutterView.textView = diffTextView
      // The clip view's bounds origin is the scroll offset, so a subview
      // placed at its minX stays put horizontally yet scrolls vertically.
      contentView.addSubview(gutterView)
      contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        self, selector: #selector(clipViewBoundsDidChange),
        name: NSView.boundsDidChangeNotification, object: contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func setContent(
      rows: [LineDiff.Row],
      highlights: [Int: AttributedString],
      theme: Theme,
      revision: String
    ) {
      guard renderedRevision != revision || renderedTheme != theme else { return }
      renderedRevision = revision
      renderedTheme = theme

      let metrics = NativeDiffMetrics(rows: rows, minimumDigits: lineNumberDigits)
      let text = Self.attributedText(
        rows: rows,
        highlights: highlights,
        font: metrics.font,
        rowHeight: metrics.rowHeight,
        foreground: NSColor(theme.textPrimary)
      )
      let colors = NativeDiffColors(theme: theme)
      diffTextView.setContent(
        text,
        rows: rows,
        metrics: metrics,
        colors: colors
      )
      gutterView.setContent(rows: rows, metrics: metrics, colors: colors)

      guard let layoutManager = diffTextView.layoutManager,
        let textContainer = diffTextView.textContainer
      else { return }
      layoutManager.ensureLayout(for: textContainer)
      let used = layoutManager.usedRect(for: textContainer)
      let contentWidth = max(
        1,
        ceil(metrics.textInset + used.maxX + metrics.trailingPadding)
      )
      // The paragraph style pins every row to the same native line box.
      // Counting those boxes also covers an empty final row, for which
      // TextKit has no glyph range to include in `usedRect`.
      let textHeight = max(ceil(used.maxY), CGFloat(rows.count) * metrics.rowHeight)
      contentFittingSize = CGSize(
        width: contentWidth,
        height: max(1, ceil(metrics.verticalPadding * 2 + textHeight))
      )
      scrollSync?.report(contentWidth: contentWidth, from: self)
      fitDocument(
        toViewportSize: CGSize(
          width: max(bounds.width, 1),
          height: visibleContentHeight
        )
      )
      // A hunk appearing mid-scroll (an expanded fold) joins at the file's
      // current offset.
      if let offset = scrollSync?.offset, offset > 0 { applySyncedOffset(offset) }
      invalidateIntrinsicContentSize()
    }

    @discardableResult
    func fitContent(toViewportWidth viewportWidth: CGFloat) -> CGSize {
      let viewportSize = CGSize(width: viewportWidth, height: visibleContentHeight)
      fitDocument(toViewportSize: viewportSize)
      return viewportSize
    }

    @objc private func clipViewBoundsDidChange(_: Notification) {
      pinGutter()
      if !isApplyingSyncedOffset {
        scrollSync?.report(offset: contentView.bounds.minX, from: self)
      }
    }

    /// Keeps the gutter at the visible left edge and the code mask just
    /// right of it, for the current horizontal scroll offset.
    private func pinGutter() {
      let offset = contentView.bounds.minX
      let gutterWidth = diffTextView.gutterWidth
      let height = diffTextView.frame.height
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gutterView.frame = CGRect(x: offset, y: 0, width: gutterWidth, height: height)
      codeMask.frame = CGRect(
        x: offset + gutterWidth, y: 0,
        width: max(0, diffTextView.frame.width - offset - gutterWidth), height: height)
      CATransaction.commit()
    }

    override func layout() {
      super.layout()
      guard bounds.width > 0 else { return }
      fitDocument(
        toViewportSize: CGSize(
          width: bounds.width,
          height: bounds.height > 0 ? min(bounds.height, visibleContentHeight) : visibleContentHeight
        )
      )
    }

    override func shouldConsumeVerticalScroll(_ event: NSEvent) -> Bool {
      canConsumeVerticalDelta(event.scrollingDeltaY)
    }

    func canConsumeVerticalDelta(_ deltaY: CGFloat) -> Bool {
      guard hasVerticalScroller, deltaY != 0 else { return false }

      let visibleRect = contentView.documentVisibleRect
      let documentRect = diffTextView.bounds
      let boundaryTolerance: CGFloat = 0.5
      if deltaY > 0 {
        return visibleRect.minY > documentRect.minY + boundaryTolerance
      }
      return visibleRect.maxY < documentRect.maxY - boundaryTolerance
    }

    private var visibleContentHeight: CGFloat {
      maximumHeight.map { min(contentFittingSize.height, $0) } ?? contentFittingSize.height
    }

    private func fitDocument(toViewportSize viewportSize: CGSize) {
      // Refitting can clamp the scroll position; that isn't the reader
      // scrolling, so it must not move the rest of the file.
      isApplyingSyncedOffset = true
      defer { isApplyingSyncedOffset = false }
      // Every hunk of a file is as wide as its widest, so they can scroll
      // together to any offset.
      let contentWidth = max(contentFittingSize.width, scrollSync?.sharedContentWidth ?? 0)
      let documentSize = CGSize(
        width: max(viewportSize.width, contentWidth),
        height: contentFittingSize.height
      )
      if diffTextView.frame.size != documentSize {
        diffTextView.setFrameSize(documentSize)
      }
      let shouldScrollHorizontally = contentWidth > viewportSize.width + 0.5
      if hasHorizontalScroller != shouldScrollHorizontally {
        hasHorizontalScroller = shouldScrollHorizontally
      }
      let shouldScrollVertically = contentFittingSize.height > viewportSize.height + 0.5
      if hasVerticalScroller != shouldScrollVertically {
        hasVerticalScroller = shouldScrollVertically
      }
      reflectScrolledClipView(contentView)
      pinGutter()
    }

    private static func attributedText(
      rows: [LineDiff.Row],
      highlights: [Int: AttributedString],
      font: NSFont,
      rowHeight: CGFloat,
      foreground: NSColor
    ) -> NSAttributedString {
      let result = NSMutableAttributedString()
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = rowHeight
      paragraph.maximumLineHeight = rowHeight

      for (index, row) in rows.enumerated() {
        if let highlighted = highlights[row.id], !row.text.isEmpty {
          for run in highlighted.runs {
            result.append(
              NSAttributedString(
                string: String(highlighted[run.range].characters),
                attributes: [
                  .font: font,
                  .foregroundColor: run.foregroundColor.map(NSColor.init)
                    ?? foreground,
                  .paragraphStyle: paragraph,
                ]
              )
            )
          }
        } else if !row.text.isEmpty {
          result.append(
            NSAttributedString(
              string: row.text,
              attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
              ]
            )
          )
        }
        if index < rows.count - 1 {
          result.append(
            NSAttributedString(
              string: "\n",
              attributes: [
                .font: font,
                .foregroundColor: foreground,
                .paragraphStyle: paragraph,
              ]
            )
          )
        }
      }
      return result
    }
  }

  @MainActor
  final class NativeDiffTextView: TranscriptSelectableTextView {
    private var rows: [LineDiff.Row] = []
    private var metrics = NativeDiffMetrics(rows: [])
    private var colors = NativeDiffColors(theme: .system)

    func setContent(
      _ text: NSAttributedString,
      rows: [LineDiff.Row],
      metrics: NativeDiffMetrics,
      colors: NativeDiffColors
    ) {
      let selection = selectedRange()
      textStorage?.beginEditing()
      textStorage?.setAttributedString(text)
      textStorage?.endEditing()
      self.rows = rows
      self.metrics = metrics
      self.colors = colors
      textContainerInset = NSSize(width: metrics.textInset, height: metrics.verticalPadding)
      let safeSelection = NSRange(
        location: min(selection.location, text.length),
        length: min(selection.length, max(0, text.length - min(selection.location, text.length)))
      )
      setSelectedRange(safeSelection)
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      drawDecorations(in: dirtyRect)
      super.draw(dirtyRect)
    }

    /// The area a row's fill covers: its line box, except that the first
    /// and last rows reach the view's edges. TextKit can measure the text a
    /// little taller than the rows, and that slack must take the edge row's
    /// color: a trailing addition stays green to the bottom, an unchanged
    /// last line stays clear.
    func rowFillRect(at index: Int) -> CGRect? {
      guard var rect = rowRect(at: index) else { return nil }
      if index == 0 {
        rect.size.height += rect.minY - bounds.minY
        rect.origin.y = bounds.minY
      }
      if index == rows.count - 1 {
        rect.size.height = max(rect.height, bounds.maxY - rect.minY)
      }
      return rect
    }

    func rowRect(at index: Int) -> CGRect? {
      guard rows.indices.contains(index) else { return nil }
      return CGRect(
        x: 0,
        y: metrics.verticalPadding + CGFloat(index) * metrics.rowHeight,
        width: bounds.width,
        height: metrics.rowHeight
      )
    }

    private func drawDecorations(in dirtyRect: CGRect) {
      guard !rows.isEmpty else { return }
      let contentMinY = max(0, dirtyRect.minY - metrics.verticalPadding)
      let contentMaxY = max(0, dirtyRect.maxY - metrics.verticalPadding)
      let first = min(rows.count - 1, max(0, Int(floor(contentMinY / metrics.rowHeight))))
      let last = min(rows.count - 1, Int(floor(contentMaxY / metrics.rowHeight)))
      guard first <= last else { return }

      for index in first...last {
        guard let fillRect = rowFillRect(at: index) else { continue }
        backgroundColor(for: rows[index].kind).setFill()
        fillRect.fill()
      }
    }

    /// The pinned gutter's width: everything left of the code.
    var gutterWidth: CGFloat { metrics.textInset - metrics.gutterSpacing }

    /// The row indices a vertical band of the view touches.
    func rowRange(in dirtyRect: CGRect) -> ClosedRange<Int>? {
      guard !rows.isEmpty else { return nil }
      let contentMinY = max(0, dirtyRect.minY - metrics.verticalPadding)
      let contentMaxY = max(0, dirtyRect.maxY - metrics.verticalPadding)
      let first = min(rows.count - 1, max(0, Int(floor(contentMinY / metrics.rowHeight))))
      let last = min(rows.count - 1, Int(floor(contentMaxY / metrics.rowHeight)))
      return first <= last ? first...last : nil
    }

    private func backgroundColor(for kind: LineDiff.Row.Kind) -> NSColor {
      switch kind {
      case .context: .clear
      case .added: colors.addedBackground
      case .removed: colors.removedBackground
      }
    }
  }

  struct NativeDiffMetrics {
    let font: NSFont
    let rowHeight: CGFloat
    /// Breathing room above the first row and below the last. The edge
    /// rows' fills extend through it (see `rowFillRect`), so a changed first
    /// or last line is tinted to the card's edge.
    let verticalPadding: CGFloat = 6
    let horizontalPadding: CGFloat = 8
    let gutterSpacing: CGFloat = 6
    let markerWidth: CGFloat = 8
    let trailingPadding: CGFloat = 8
    let gutterWidth: CGFloat

    init(rows: [LineDiff.Row], minimumDigits: Int = 2) {
      font = NSFont.monospacedSystemFont(
        ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
        weight: .regular
      )
      rowHeight = ceil(NSLayoutManager().defaultLineHeight(for: font)) + 2
      let maxLine = rows.reduce(1) { partial, row in
        max(partial, row.oldLine ?? 0, row.newLine ?? 0)
      }
      let digits = max(minimumDigits, String(maxLine).count)
      let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
      gutterWidth = CGFloat(digits) * digitWidth
    }

    var textInset: CGFloat {
      horizontalPadding + gutterWidth + gutterSpacing + gutterWidth
        + gutterSpacing + markerWidth + gutterSpacing
    }

    func oldNumberRect(_ rowRect: CGRect) -> CGRect {
      CGRect(
        x: horizontalPadding,
        y: rowRect.minY,
        width: gutterWidth,
        height: rowRect.height
      )
    }

    func newNumberRect(_ rowRect: CGRect) -> CGRect {
      CGRect(
        x: horizontalPadding + gutterWidth + gutterSpacing,
        y: rowRect.minY,
        width: gutterWidth,
        height: rowRect.height
      )
    }

    func markerRect(_ rowRect: CGRect) -> CGRect {
      CGRect(
        x: horizontalPadding + gutterWidth + gutterSpacing + gutterWidth + gutterSpacing,
        y: rowRect.minY,
        width: markerWidth,
        height: rowRect.height
      )
    }
  }

  struct NativeDiffColors {
    let lineNumber: NSColor
    let addedForeground: NSColor
    let removedForeground: NSColor
    let addedBackground: NSColor
    let removedBackground: NSColor
    /// The gutter's own faint band, so numbers read as chrome, not code.
    let gutterBackground: NSColor

    init(theme: Theme) {
      lineNumber = NSColor(theme.diffLineNumberFg)
      addedForeground = NSColor(theme.diffAddedFg)
      removedForeground = NSColor(theme.diffRemovedFg)
      addedBackground = NSColor(theme.diffAddedBg)
      removedBackground = NSColor(theme.diffRemovedBg)
      gutterBackground = NSColor(theme.diffLineNumberFg).withAlphaComponent(0.08)
    }
  }
  extension NativeDiffScrollView: DiffScrollSyncMember {
    func applySyncedOffset(_ offset: CGFloat) {
      let maximum = max(0, diffTextView.frame.width - contentView.bounds.width)
      let target = NSPoint(x: min(offset, maximum), y: contentView.bounds.minY)
      guard abs(contentView.bounds.minX - target.x) > 0.5 else { return }
      isApplyingSyncedOffset = true
      contentView.scroll(to: target)
      reflectScrolledClipView(contentView)
      isApplyingSyncedOffset = false
    }

    func syncedContentWidthChanged() {
      needsLayout = true
    }
  }
#endif
