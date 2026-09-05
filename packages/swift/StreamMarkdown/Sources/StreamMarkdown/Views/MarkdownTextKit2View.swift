#if canImport(AppKit)
  import AppKit
  import QuickLookUI

  /// A settled Markdown text surface backed exclusively by TextKit 2.
  ///
  /// Unlike ``SelectableTextKitView``, this view never asks for the legacy
  /// `layoutManager` property. That keeps viewport-based, noncontiguous text
  /// layout enabled for the lifetime of the surface.
  @MainActor
  final class MarkdownTextKit2View: TranscriptSurfaceTextView, NSTextViewDelegate {
    private lazy var markdownLayoutDelegate = MarkdownTextLayoutDelegate()
    /// NSTextLayoutManager keeps a weak reference to its content manager;
    /// the view owns the TextKit 2 root for the lifetime of the surface.
    private let markdownContentStorage: NSTextContentStorage
    private var representedText: NSAttributedString?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1
    var linkAction: MarkdownLinkAction?

    var usesTextKit2: Bool { textLayoutManager != nil }

    init() {
      let contentStorage = NSTextContentStorage()
      let layoutManager = NSTextLayoutManager()
      let container = NSTextContainer(
        size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude)
      )
      contentStorage.addTextLayoutManager(layoutManager)
      layoutManager.textContainer = container
      markdownContentStorage = contentStorage
      super.init(frame: .zero, textContainer: container)

      isEditable = false
      isSelectable = true
      isRichText = true
      drawsBackground = false
      textContainerInset = .zero
      isHorizontallyResizable = false
      isVerticallyResizable = true
      minSize = .zero
      maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      focusRingType = .none
      allowsUndo = false
      isContinuousSpellCheckingEnabled = false
      isGrammarCheckingEnabled = false
      isAutomaticSpellingCorrectionEnabled = false
      isAutomaticTextReplacementEnabled = false
      isAutomaticQuoteSubstitutionEnabled = false
      isAutomaticDashSubstitutionEnabled = false
      isAutomaticLinkDetectionEnabled = false
      linkTextAttributes = [
        .foregroundColor: NSColor.linkColor,
        .cursor: NSCursor.pointingHand,
      ]
      textContainer?.lineFragmentPadding = 0
      // A text container supplied to NSTextView does not automatically
      // track the view's width. Transcript virtualization repeatedly
      // detaches and remounts these views; without this contract AppKit
      // can restore the container's original 1pt width while leaving the
      // NSTextView itself full-width, wrapping every character.
      textContainer?.widthTracksTextView = true
      // TextKit 1's transcript renderer advances by ascender/descender
      // plus paragraph line spacing. TextKit 2 includes font leading by
      // default, producing a visible line-height jump when streaming
      // content settles. Disabling it preserves the established metrics
      // to the nearest display pixel while retaining TextKit 2 layout.
      textLayoutManager?.usesFontLeading = false
      textLayoutManager?.delegate = markdownLayoutDelegate
      delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned, selectedRange().length > 0 {
        setSelectedRange(NSRange(location: NSMaxRange(selectedRange()), length: 0))
      }
      return resigned
    }

    func setContent(_ text: NSAttributedString) {
      guard representedText !== text else { return }
      if let representedText, representedText.isEqual(to: text) {
        self.representedText = text
        return
      }

      let selection = selectedRange()
      representedText = text
      measuredWidth = -1
      textStorage?.setAttributedString(Self.textKit2Links(in: text))
      let location = min(selection.location, text.length)
      let length = min(selection.length, text.length - location)
      setSelectedRange(NSRange(location: location, length: length))
      needsDisplay = true
    }

    override func layout() {
      synchronizeTextContainerWidth(with: bounds.width)
      super.layout()
    }

    func contentHeight(forWidth proposedWidth: CGFloat) -> CGFloat {
      let width = max(1, proposedWidth)
      let containerWidth = textContainer?.size.width ?? -1
      if abs(measuredWidth - width) <= 0.25,
        abs(containerWidth - width) <= 0.25
      {
        return measuredHeight
      }

      if abs(frame.width - width) > 0.25 {
        setFrameSize(NSSize(width: width, height: max(1, frame.height)))
      }
      guard let textLayoutManager, textContainer != nil else { return 1 }
      synchronizeTextContainerWidth(with: width)
      textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
      measuredWidth = width
      measuredHeight = max(
        1,
        ceil(textLayoutManager.usageBoundsForTextContainer.height)
      )
      return measuredHeight
    }

    private func synchronizeTextContainerWidth(with proposedWidth: CGFloat) {
      guard let textContainer else { return }
      let width = max(1, proposedWidth)
      guard abs(textContainer.size.width - width) > 0.25 else { return }
      textContainer.size = NSSize(
        width: width,
        height: CGFloat.greatestFiniteMagnitude
      )
      measuredWidth = -1
    }

    /// A link click makes this text view first responder, and `NSTextView`
    /// would then claim the shared Quick Look panel to preview the link's
    /// raw value — the workspace path shown as an Internet Location card.
    /// The host's preview controller presents the fetched file instead.
    override func acceptsPreviewPanelControl(_: QLPreviewPanel!) -> Bool {
      false
    }

    func textView(_: NSTextView, clickedOnLink link: Any, at _: Int) -> Bool {
      let url: URL?
      switch link {
      case let value as URL: url = value
      case let value as String: url = URL(string: value)
      default: url = nil
      }
      guard let url, let linkAction else { return false }
      return linkAction(url)
    }

    /// TextKit 2 delegates link interaction through `.link`. The existing
    /// renderer keeps server-file links in a host-owned custom attribute,
    /// so mirror that value into `.link` only for this native surface.
    private static func textKit2Links(in text: NSAttributedString) -> NSAttributedString {
      let result = NSMutableAttributedString(attributedString: text)
      var links: [(value: Any, range: NSRange)] = []
      result.enumerateAttribute(
        .streamMarkdownServerFileLink,
        in: NSRange(location: 0, length: result.length)
      ) { value, range, _ in
        guard let value else { return }
        links.append((value, range))
      }
      for link in links {
        result.addAttribute(.link, value: link.value, range: link.range)
      }
      return result
    }
  }

  private final class MarkdownTextLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
    func textLayoutManager(
      _: NSTextLayoutManager,
      textLayoutFragmentFor _: any NSTextLocation,
      in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
      MarkdownTextLayoutFragment(textElement: textElement, range: nil)
    }
  }

  /// TextKit 2 equivalent of the old custom layout manager's decorations.
  /// The glyph layout remains entirely owned by TextKit 2; this subclass only
  /// paints quote bars and rounded inline-code fills before the standard text.
  private final class MarkdownTextLayoutFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) {
      drawQuoteBars(at: point, in: context)
      drawRoundedBackgrounds(at: point, in: context)
      super.draw(at: point, in: context)
    }

    private var attributedText: NSAttributedString? {
      (textElement as? NSTextParagraph)?.attributedString
    }

    /// A layout fragment is one paragraph, and a quote decorates whole
    /// paragraphs (including the spacing runs between them), so the bar
    /// covers the fragment's full frame. Fragments tile the container, so
    /// consecutive quoted paragraphs join into one rule with no seam.
    private func drawQuoteBars(at point: CGPoint, in context: CGContext) {
      guard let decoration = quoteDecoration else { return }
      let origin = CGPoint(x: point.x - layoutFragmentFrame.minX, y: point.y)
      for rect in quoteBarRects(decoration) {
        TextKitQuoteBarPainter.fill(
          rect.offsetBy(dx: origin.x, dy: origin.y),
          color: decoration.color,
          in: context
        )
      }
    }

    /// The bars sit at the container's left edge, outside the indented
    /// paragraph frame — and a spacing run between quoted paragraphs has a
    /// zero-width frame. TextKit 2 culls and invalidates fragments by these
    /// bounds, so without the bars declared here the spacers are never
    /// drawn (gaps) and partial redraws re-composite the translucent bar
    /// over itself (darker bands).
    override var renderingSurfaceBounds: CGRect {
      var bounds = super.renderingSurfaceBounds
      guard let decoration = quoteDecoration else { return bounds }
      for rect in quoteBarRects(decoration) {
        bounds = bounds.union(rect.offsetBy(dx: -layoutFragmentFrame.minX, dy: 0))
      }
      return bounds
    }

    private var quoteDecoration: TextKitQuoteDecoration? {
      guard let attributedText, attributedText.length > 0 else { return nil }
      return attributedText.attribute(
        .streamMarkdownQuoteDecoration,
        at: 0,
        effectiveRange: nil
      ) as? TextKitQuoteDecoration
    }

    /// Bar rects in container coordinates for this fragment's vertical span.
    private func quoteBarRects(_ decoration: TextKitQuoteDecoration) -> [CGRect] {
      decoration.barOffsets.map { offset in
        CGRect(
          x: offset,
          y: 0,
          width: decoration.barWidth,
          height: layoutFragmentFrame.height
        )
      }
    }

    private func drawRoundedBackgrounds(at point: CGPoint, in context: CGContext) {
      guard let attributedText else { return }
      for line in textLineFragments {
        let lineRange = validRange(line.characterRange, in: attributedText)
        guard lineRange.length > 0 else { continue }
        // Join matching backgrounds across link and foreground-color runs,
        // including the unlinked padding on either side of inline code.
        attributedText.enumerateAttribute(
          .streamMarkdownRoundedBackground,
          in: lineRange,
          options: []
        ) { value, attributeRange, _ in
          guard let background = value as? TextKitRoundedBackground else { return }
          let range = NSIntersectionRange(lineRange, attributeRange)
          guard range.length > 0 else { return }

          let start = line.locationForCharacter(at: range.location)
          let end = line.locationForCharacter(at: NSMaxRange(range))
          let minX = min(start.x, end.x)
          let width = max(1, abs(end.x - start.x))
          let rect = CGRect(
            x: point.x + line.typographicBounds.minX + minX,
            y: point.y + line.typographicBounds.minY + 0.5,
            width: width,
            height: max(1, line.typographicBounds.height - 1)
          )
          context.saveGState()
          context.setFillColor(background.color.cgColor)
          let radius = min(background.cornerRadius, rect.height / 2)
          context.addPath(
            CGPath(
              roundedRect: rect,
              cornerWidth: radius,
              cornerHeight: radius,
              transform: nil
            )
          )
          context.fillPath()
          context.restoreGState()
        }
      }
    }

    private func validRange(_ range: NSRange, in text: NSAttributedString) -> NSRange {
      guard range.location != NSNotFound, range.location < text.length else {
        return NSRange(location: 0, length: 0)
      }
      return NSIntersectionRange(range, NSRange(location: 0, length: text.length))
    }
  }
#endif
