#if canImport(UIKit) && !canImport(AppKit)
  import StreamMarkdown
  import SwiftUI
  import TranscriptKit
  import UIKit

  /// A complete file diff rendered by one UIKit/TextKit surface. The outer
  /// scroll view owns both axes, while the text view remains selectable.
  /// Line numbers and change markers live in a gutter that stays put while
  /// long lines scroll sideways beneath it, as in GitHub's mobile review.
  struct IOSNativeDiffView: UIViewRepresentable {
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

    func makeUIView(context _: Context) -> IOSNativeDiffScrollView {
      let scrollView = IOSNativeDiffScrollView()
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

    func updateUIView(_ scrollView: IOSNativeDiffScrollView, context _: Context) {
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
      uiView scrollView: IOSNativeDiffScrollView,
      context _: Context
    ) -> CGSize? {
      let width =
        proposal.width.flatMap { $0.isFinite ? $0 : nil }
        ?? scrollView.contentFittingSize.width
      return scrollView.fitContent(toViewportWidth: max(1, width))
    }
  }

  @MainActor
  final class IOSNativeDiffScrollView: UIScrollView {
    private(set) var diffTextView: IOSNativeDiffTextView
    private let gutterView = IOSNativeDiffGutterView()
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

    override init(frame: CGRect) {
      let textStorage = NSTextStorage()
      let layoutManager = NSLayoutManager()
      textStorage.addLayoutManager(layoutManager)
      let textContainer = NSTextContainer(
        size: CGSize(
          width: CGFloat.greatestFiniteMagnitude,
          height: CGFloat.greatestFiniteMagnitude
        )
      )
      textContainer.lineFragmentPadding = 0
      textContainer.widthTracksTextView = false
      textContainer.heightTracksTextView = false
      layoutManager.addTextContainer(textContainer)
      diffTextView = IOSNativeDiffTextView(frame: .zero, textContainer: textContainer)

      super.init(frame: frame)
      backgroundColor = .clear
      clipsToBounds = true
      contentInsetAdjustmentBehavior = .never
      automaticallyAdjustsScrollIndicatorInsets = false
      alwaysBounceHorizontal = false
      alwaysBounceVertical = false
      bounces = false
      isDirectionalLockEnabled = true
      delaysContentTouches = false

      diffTextView.isEditable = false
      diffTextView.isSelectable = true
      diffTextView.isScrollEnabled = false
      diffTextView.backgroundColor = .clear
      diffTextView.textContainer.lineFragmentPadding = 0
      diffTextView.textContainerInset = .zero
      diffTextView.adjustsFontForContentSizeCategory = true
      addSubview(diffTextView)
      codeMask.backgroundColor = UIColor.black.cgColor
      diffTextView.layer.mask = codeMask
      gutterView.textView = diffTextView
      addSubview(gutterView)
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

      let metrics = IOSNativeDiffMetrics(rows: rows, minimumDigits: lineNumberDigits)
      let text = Self.attributedText(
        rows: rows,
        highlights: highlights,
        font: metrics.font,
        rowHeight: metrics.rowHeight,
        foreground: UIColor(theme.textPrimary)
      )
      let colors = IOSNativeDiffColors(theme: theme)
      diffTextView.setContent(
        text,
        rows: rows,
        metrics: metrics,
        colors: colors
      )
      gutterView.setContent(rows: rows, metrics: metrics, colors: colors)

      let layoutManager = diffTextView.layoutManager
      let textContainer = diffTextView.textContainer
      layoutManager.ensureLayout(for: textContainer)
      let used = layoutManager.usedRect(for: textContainer)
      let contentWidth = max(
        1,
        ceil(metrics.textInset + used.maxX + metrics.trailingPadding)
      )
      let textHeight = max(ceil(used.maxY), CGFloat(rows.count) * metrics.rowHeight)
      contentFittingSize = CGSize(
        width: contentWidth, height: max(1, ceil(metrics.verticalPadding * 2 + textHeight)))
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
      setNeedsLayout()
    }

    @discardableResult
    func fitContent(toViewportWidth viewportWidth: CGFloat) -> CGSize {
      let viewportSize = CGSize(width: viewportWidth, height: visibleContentHeight)
      fitDocument(toViewportSize: viewportSize)
      return viewportSize
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard bounds.width > 0 else { return }
      // Scrolling lays the view out on every step: share the reader's
      // offset with the file's other hunks. Only the reader's own scrolls
      // count; layout clamping or following the group must not broadcast.
      if isTracking || isDragging || isDecelerating {
        scrollSync?.report(offset: contentOffset.x, from: self)
      }
      fitDocument(
        toViewportSize: CGSize(
          width: bounds.width,
          height: bounds.height > 0 ? min(bounds.height, visibleContentHeight) : visibleContentHeight
        )
      )
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard gestureRecognizer === panGestureRecognizer else {
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
      }

      // A slow, deliberate pan starts with almost no velocity; fall back to
      // how far it has moved so a sideways drag still reads as horizontal.
      var velocity = panGestureRecognizer.velocity(in: self)
      if abs(velocity.x) < 1, abs(velocity.y) < 1 {
        velocity = panGestureRecognizer.translation(in: self)
      }
      if abs(velocity.y) >= abs(velocity.x) {
        let canConsume = DiffScrollConsumptionPolicy.canConsume(
          contentDelta: -velocity.y,
          offset: contentOffset.y,
          contentLength: contentSize.height,
          viewportLength: bounds.height
        )
        return canConsume && super.gestureRecognizerShouldBegin(gestureRecognizer)
      }

      let canConsume = DiffScrollConsumptionPolicy.canConsume(
        contentDelta: -velocity.x,
        offset: contentOffset.x,
        contentLength: contentSize.width,
        viewportLength: bounds.width
      )
      return canConsume && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    private var visibleContentHeight: CGFloat {
      maximumHeight.map { min(contentFittingSize.height, $0) } ?? contentFittingSize.height
    }

    private func fitDocument(toViewportSize viewportSize: CGSize) {
      // Every hunk of a file is as wide as its widest, so they can scroll
      // together to any offset.
      let contentWidth = max(contentFittingSize.width, scrollSync?.sharedContentWidth ?? 0)
      let documentSize = CGSize(
        width: max(viewportSize.width, contentWidth),
        height: contentFittingSize.height
      )
      if diffTextView.frame.size != documentSize {
        diffTextView.frame = CGRect(origin: .zero, size: documentSize)
      }
      if contentSize != documentSize {
        contentSize = documentSize
      }

      let scrollsHorizontally = contentWidth > viewportSize.width + 0.5
      let scrollsVertically = contentFittingSize.height > viewportSize.height + 0.5
      showsHorizontalScrollIndicator = scrollsHorizontally
      showsVerticalScrollIndicator = scrollsVertically
      isScrollEnabled = scrollsHorizontally || scrollsVertically

      let maximumOffset = CGPoint(
        x: max(0, documentSize.width - viewportSize.width),
        y: max(0, documentSize.height - viewportSize.height)
      )
      let clampedOffset = CGPoint(
        x: min(max(0, contentOffset.x), maximumOffset.x),
        y: min(max(0, contentOffset.y), maximumOffset.y)
      )
      if contentOffset != clampedOffset {
        contentOffset = clampedOffset
      }
      pinGutter()
    }

    /// Keeps the gutter at the visible left edge. Runs from `layoutSubviews`,
    /// which a scroll view gets on every scroll step.
    private func pinGutter() {
      let gutterWidth = diffTextView.gutterWidth
      let height = diffTextView.bounds.height
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      gutterView.frame = CGRect(x: contentOffset.x, y: 0, width: gutterWidth, height: height)
      codeMask.frame = CGRect(
        x: contentOffset.x + gutterWidth, y: 0,
        width: max(0, diffTextView.bounds.width - contentOffset.x - gutterWidth), height: height)
      CATransaction.commit()
    }

    private static func attributedText(
      rows: [LineDiff.Row],
      highlights: [Int: AttributedString],
      font: UIFont,
      rowHeight: CGFloat,
      foreground: UIColor
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
                  .foregroundColor: run.foregroundColor.map(UIColor.init)
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

  extension IOSNativeDiffScrollView: DiffScrollSyncMember {
    func applySyncedOffset(_ offset: CGFloat) {
      let maximum = max(0, contentSize.width - bounds.width)
      let target = min(offset, maximum)
      guard abs(contentOffset.x - target) > 0.5 else { return }
      contentOffset = CGPoint(x: target, y: contentOffset.y)
    }

    func syncedContentWidthChanged() {
      setNeedsLayout()
    }
  }

  @MainActor
  final class IOSNativeDiffTextView: UITextView {
    private var rows: [LineDiff.Row] = []
    private var metrics = IOSNativeDiffMetrics(rows: [])
    private var colors = IOSNativeDiffColors(theme: .system)

    func setContent(
      _ text: NSAttributedString,
      rows: [LineDiff.Row],
      metrics: IOSNativeDiffMetrics,
      colors: IOSNativeDiffColors
    ) {
      let selection = selectedRange
      textStorage.beginEditing()
      textStorage.setAttributedString(text)
      textStorage.endEditing()
      self.rows = rows
      self.metrics = metrics
      self.colors = colors
      textContainerInset = UIEdgeInsets(
        top: metrics.verticalPadding, left: metrics.textInset, bottom: metrics.verticalPadding, right: 0)
      selectedRange = NSRange(
        location: min(selection.location, text.length),
        length: min(selection.length, max(0, text.length - min(selection.location, text.length)))
      )
      setNeedsDisplay()
    }

    /// The pinned gutter's width: everything left of the code.
    var gutterWidth: CGFloat { metrics.textInset - metrics.gutterSpacing }

    override func draw(_ rect: CGRect) {
      drawDecorations(in: rect)
      super.draw(rect)
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
        UIRectFill(fillRect)
      }
    }

    /// The row indices a vertical band of the view touches.
    func rowRange(in dirtyRect: CGRect) -> ClosedRange<Int>? {
      guard !rows.isEmpty else { return nil }
      let contentMinY = max(0, dirtyRect.minY - metrics.verticalPadding)
      let contentMaxY = max(0, dirtyRect.maxY - metrics.verticalPadding)
      let first = min(rows.count - 1, max(0, Int(floor(contentMinY / metrics.rowHeight))))
      let last = min(rows.count - 1, Int(floor(contentMaxY / metrics.rowHeight)))
      return first <= last ? first...last : nil
    }

    private func backgroundColor(for kind: LineDiff.Row.Kind) -> UIColor {
      switch kind {
      case .context: .clear
      case .added: colors.addedBackground
      case .removed: colors.removedBackground
      }
    }
  }

  struct IOSNativeDiffMetrics {
    let font: UIFont
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
      font = UIFont.monospacedSystemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
        weight: .regular
      )
      rowHeight = ceil(font.lineHeight) + 2
      let maxLine = rows.reduce(1) { partial, row in
        max(partial, row.oldLine ?? 0, row.newLine ?? 0)
      }
      let digits = max(minimumDigits, String(maxLine).count)
      let digitWidth = ceil(("0" as NSString).size(withAttributes: [.font: font]).width)
      gutterWidth = CGFloat(digits) * digitWidth
    }

    /// One number column on iPhone, where width is scarce: the new line
    /// number, or the old one for a removed line.
    var textInset: CGFloat {
      horizontalPadding + gutterWidth + gutterSpacing + markerWidth + gutterSpacing + gutterSpacing
    }

    func numberRect(_ rowRect: CGRect) -> CGRect {
      CGRect(
        x: horizontalPadding,
        y: rowRect.minY,
        width: gutterWidth,
        height: rowRect.height
      )
    }

    func markerRect(_ rowRect: CGRect) -> CGRect {
      CGRect(
        x: horizontalPadding + gutterWidth + gutterSpacing,
        y: rowRect.minY,
        width: markerWidth,
        height: rowRect.height
      )
    }
  }

  struct IOSNativeDiffColors {
    let lineNumber: UIColor
    let addedForeground: UIColor
    let removedForeground: UIColor
    let addedBackground: UIColor
    let removedBackground: UIColor
    /// The gutter's own faint band, so numbers read as chrome, not code.
    let gutterBackground: UIColor

    init(theme: Theme) {
      lineNumber = UIColor(theme.diffLineNumberFg)
      addedForeground = UIColor(theme.diffAddedFg)
      removedForeground = UIColor(theme.diffRemovedFg)
      addedBackground = UIColor(theme.diffAddedBg)
      removedBackground = UIColor(theme.diffRemovedBg)
      gutterBackground = UIColor(theme.diffLineNumberFg).withAlphaComponent(0.08)
    }
  }
#endif
