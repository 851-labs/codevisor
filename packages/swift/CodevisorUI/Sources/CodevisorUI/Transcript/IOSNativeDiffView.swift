#if canImport(UIKit) && !canImport(AppKit)
  import StreamMarkdown
  import SwiftUI
  import TranscriptKit
  import UIKit

  /// A complete file diff rendered by one UIKit/TextKit surface. The outer
  /// scroll view owns both axes, while the text view remains selectable.
  struct IOSNativeDiffView: UIViewRepresentable {
    let rows: [LineDiff.Row]
    let highlights: [Int: AttributedString]
    let theme: Theme
    let revision: String

    func makeUIView(context _: Context) -> IOSNativeDiffScrollView {
      let scrollView = IOSNativeDiffScrollView()
      scrollView.setContent(
        rows: rows,
        highlights: highlights,
        theme: theme,
        revision: revision
      )
      return scrollView
    }

    func updateUIView(_ scrollView: IOSNativeDiffScrollView, context _: Context) {
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
    private(set) var contentFittingSize = CGSize(width: 1, height: 1)
    private var renderedRevision: String?
    private var renderedTheme: Theme?

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

      let metrics = IOSNativeDiffMetrics(rows: rows)
      let text = Self.attributedText(
        rows: rows,
        highlights: highlights,
        font: metrics.font,
        rowHeight: metrics.rowHeight,
        foreground: UIColor(theme.textPrimary)
      )
      diffTextView.setContent(
        text,
        rows: rows,
        metrics: metrics,
        colors: IOSNativeDiffColors(theme: theme)
      )

      let layoutManager = diffTextView.layoutManager
      let textContainer = diffTextView.textContainer
      layoutManager.ensureLayout(for: textContainer)
      let used = layoutManager.usedRect(for: textContainer)
      let contentWidth = max(
        1,
        ceil(metrics.textInset + used.maxX + metrics.trailingPadding)
      )
      let textHeight = max(ceil(used.maxY), CGFloat(rows.count) * metrics.rowHeight)
      contentFittingSize = CGSize(width: contentWidth, height: max(1, textHeight))
      fitDocument(
        toViewportSize: CGSize(
          width: max(bounds.width, 1),
          height: visibleContentHeight
        )
      )
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

      let velocity = panGestureRecognizer.velocity(in: self)
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
      min(contentFittingSize.height, DiffViewportMetrics.maximumHeight)
    }

    private func fitDocument(toViewportSize viewportSize: CGSize) {
      let documentSize = CGSize(
        width: max(viewportSize.width, contentFittingSize.width),
        height: contentFittingSize.height
      )
      if diffTextView.frame.size != documentSize {
        diffTextView.frame = CGRect(origin: .zero, size: documentSize)
      }
      if contentSize != documentSize {
        contentSize = documentSize
      }

      let scrollsHorizontally = contentFittingSize.width > viewportSize.width + 0.5
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
      textContainerInset = UIEdgeInsets(top: 0, left: metrics.textInset, bottom: 0, right: 0)
      selectedRange = NSRange(
        location: min(selection.location, text.length),
        length: min(selection.length, max(0, text.length - min(selection.location, text.length)))
      )
      setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
      drawDecorations(in: rect)
      super.draw(rect)
    }

    func rowRect(at index: Int) -> CGRect? {
      guard rows.indices.contains(index) else { return nil }
      return CGRect(
        x: 0,
        y: CGFloat(index) * metrics.rowHeight,
        width: bounds.width,
        height: metrics.rowHeight
      )
    }

    private func drawDecorations(in dirtyRect: CGRect) {
      guard !rows.isEmpty else { return }
      let first = max(0, Int(floor(max(0, dirtyRect.minY) / metrics.rowHeight)))
      let last = min(rows.count - 1, Int(floor(max(0, dirtyRect.maxY) / metrics.rowHeight)))
      guard first <= last else { return }

      for index in first...last {
        guard let rowRect = rowRect(at: index) else { continue }
        let row = rows[index]
        backgroundColor(for: row.kind).setFill()
        UIRectFill(rowRect)
        drawGutter(for: row, in: rowRect)
      }
    }

    private func drawGutter(for row: LineDiff.Row, in rowRect: CGRect) {
      let numberColor: UIColor
      switch row.kind {
      case .context: numberColor = colors.lineNumber
      case .added: numberColor = colors.addedForeground
      case .removed: numberColor = colors.removedForeground
      }
      let attributes: [NSAttributedString.Key: Any] = [
        .font: metrics.font,
        .foregroundColor: numberColor,
      ]
      drawRightAligned(
        row.oldLine.map(String.init) ?? "",
        in: metrics.oldNumberRect(rowRect),
        attributes: attributes
      )
      drawRightAligned(
        row.newLine.map(String.init) ?? "",
        in: metrics.newNumberRect(rowRect),
        attributes: attributes
      )

      let marker: String
      let markerColor: UIColor
      switch row.kind {
      case .context:
        return
      case .added:
        marker = "+"
        markerColor = colors.addedForeground
      case .removed:
        marker = "-"
        markerColor = colors.removedForeground
      }
      drawCentered(
        marker,
        in: metrics.markerRect(rowRect),
        attributes: [.font: metrics.font, .foregroundColor: markerColor]
      )
    }

    private func drawRightAligned(
      _ string: String,
      in rect: CGRect,
      attributes: [NSAttributedString.Key: Any]
    ) {
      guard !string.isEmpty else { return }
      let size = (string as NSString).size(withAttributes: attributes)
      (string as NSString).draw(
        at: CGPoint(
          x: rect.maxX - size.width,
          y: rect.minY + floor((rect.height - size.height) / 2)
        ),
        withAttributes: attributes
      )
    }

    private func drawCentered(
      _ string: String,
      in rect: CGRect,
      attributes: [NSAttributedString.Key: Any]
    ) {
      let size = (string as NSString).size(withAttributes: attributes)
      (string as NSString).draw(
        at: CGPoint(
          x: rect.minX + floor((rect.width - size.width) / 2),
          y: rect.minY + floor((rect.height - size.height) / 2)
        ),
        withAttributes: attributes
      )
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
    let horizontalPadding: CGFloat = 8
    let gutterSpacing: CGFloat = 6
    let markerWidth: CGFloat = 8
    let trailingPadding: CGFloat = 8
    let gutterWidth: CGFloat

    init(rows: [LineDiff.Row]) {
      font = UIFont.monospacedSystemFont(
        ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize,
        weight: .regular
      )
      rowHeight = ceil(font.lineHeight) + 2
      let maxLine = rows.reduce(1) { partial, row in
        max(partial, row.oldLine ?? 0, row.newLine ?? 0)
      }
      let digits = max(2, String(maxLine).count)
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

  struct IOSNativeDiffColors {
    let lineNumber: UIColor
    let addedForeground: UIColor
    let removedForeground: UIColor
    let addedBackground: UIColor
    let removedBackground: UIColor

    init(theme: Theme) {
      lineNumber = UIColor(theme.diffLineNumberFg)
      addedForeground = UIColor(theme.diffAddedFg)
      removedForeground = UIColor(theme.diffRemovedFg)
      addedBackground = UIColor(theme.diffAddedBg)
      removedBackground = UIColor(theme.diffRemovedBg)
    }
  }
#endif
