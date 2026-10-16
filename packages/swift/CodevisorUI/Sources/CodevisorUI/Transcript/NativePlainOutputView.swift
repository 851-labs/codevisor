#if canImport(AppKit)
  import AppKit
  import CodeHighlighter
  import StreamMarkdown
  import SwiftUI

  struct NativePlainOutputView: NSViewRepresentable {
    let text: String
    let followsTail: Bool
    var command: String? = nil
    var syntax: [[CodeHighlighter.Token]]? = nil

    func makeNSView(context _: Context) -> NativePlainOutputScrollView {
      let scrollView = NativePlainOutputScrollView()
      scrollView.setContent(text: text, command: command, followsTail: followsTail, syntax: syntax)
      return scrollView
    }

    func updateNSView(_ scrollView: NativePlainOutputScrollView, context _: Context) {
      scrollView.setContent(text: text, command: command, followsTail: followsTail, syntax: syntax)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize,
      nsView scrollView: NativePlainOutputScrollView,
      context _: Context
    ) -> CGSize? {
      let width =
        proposal.width.flatMap { $0.isFinite ? $0 : nil }
        ?? scrollView.contentFittingSize.width
      return scrollView.fitContent(toViewportWidth: max(1, width))
    }
  }

  @MainActor
  final class NativePlainOutputScrollView: TranscriptHorizontalScrollView {
    private(set) var outputTextView: TranscriptSelectableTextView
    private(set) var contentFittingSize = CGSize(width: 1, height: 1)

    private let metrics = NativePlainOutputMetrics()
    private var renderedText: String?
    private var renderedCommand: String?
    private var renderedSyntax: [[CodeHighlighter.Token]]?

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
      outputTextView = TranscriptSelectableTextView(frame: .zero, textContainer: textContainer)

      super.init(frame: frameRect)
      drawsBackground = false
      borderType = .noBorder
      hasHorizontalScroller = false
      hasVerticalScroller = false
      autohidesScrollers = true
      scrollerStyle = .overlay
      horizontalScrollElasticity = .automatic
      automaticallyAdjustsContentInsets = false

      outputTextView.isEditable = false
      outputTextView.isSelectable = true
      outputTextView.isRichText = true
      outputTextView.drawsBackground = false
      outputTextView.isHorizontallyResizable = true
      outputTextView.isVerticallyResizable = true
      outputTextView.minSize = .zero
      outputTextView.maxSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
      outputTextView.focusRingType = .none
      outputTextView.allowsUndo = false
      outputTextView.isContinuousSpellCheckingEnabled = false
      outputTextView.isGrammarCheckingEnabled = false
      outputTextView.isAutomaticSpellingCorrectionEnabled = false
      outputTextView.isAutomaticTextReplacementEnabled = false
      outputTextView.isAutomaticQuoteSubstitutionEnabled = false
      outputTextView.isAutomaticDashSubstitutionEnabled = false
      outputTextView.isAutomaticLinkDetectionEnabled = false
      outputTextView.textContainerInset = NSSize(
        width: metrics.horizontalPadding,
        height: metrics.verticalPadding
      )
      documentView = outputTextView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func setContent(
      text output: String, command: String? = nil, followsTail: Bool,
      syntax: [[CodeHighlighter.Token]]? = nil
    ) {
      let text = command.map { output.isEmpty ? $0 : "\($0)\n\(output)" } ?? output
      guard
        renderedText != text || renderedCommand != command
          || renderedSyntax != syntax
      else { return }

      let shouldFollowTail = followsTail && (renderedText == nil || isAtBottom)
      let oldText = renderedText
      let selection = outputTextView.selectedRange()
      let primary: NSColor = .labelColor
      let foreground = command == nil ? primary : .secondaryLabelColor

      outputTextView.textStorage?.beginEditing()
      if let oldText, renderedCommand == command, renderedSyntax == syntax,
        text.hasPrefix(oldText)
      {
        let suffix = String(text.dropFirst(oldText.count))
        if !suffix.isEmpty {
          outputTextView.textStorage?.append(attributedText(suffix, foreground: foreground))
        }
      } else {
        let document = NSMutableAttributedString(attributedString: attributedText(text, foreground: foreground))
        if let command {
          document.addAttribute(
            .foregroundColor,
            value: primary,
            range: NSRange(location: 0, length: (command as NSString).length)
          )
        }
        outputTextView.textStorage?.setAttributedString(document)
        if let syntax, let storage = outputTextView.textStorage {
          PlainOutputSyntax.apply(syntax, to: storage)
        }
      }
      outputTextView.textStorage?.endEditing()
      renderedText = text
      renderedCommand = command
      renderedSyntax = syntax

      let length = outputTextView.textStorage?.length ?? 0
      outputTextView.setSelectedRange(
        NSRange(
          location: min(selection.location, length),
          length: min(selection.length, max(0, length - min(selection.location, length)))
        )
      )

      measureContent(text: text)
      fitDocument(
        toViewportSize: CGSize(width: max(bounds.width, 1), height: visibleContentHeight)
      )
      if shouldFollowTail { scrollToBottom() }
      invalidateIntrinsicContentSize()
    }

    @discardableResult
    func fitContent(toViewportWidth viewportWidth: CGFloat) -> CGSize {
      let viewportSize = CGSize(width: viewportWidth, height: visibleContentHeight)
      fitDocument(toViewportSize: viewportSize)
      return viewportSize
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
      let documentRect = outputTextView.bounds
      if deltaY > 0 {
        return visibleRect.minY > documentRect.minY + 0.5
      }
      return visibleRect.maxY < documentRect.maxY - 0.5
    }

    private var visibleContentHeight: CGFloat {
      min(contentFittingSize.height, DiffViewportMetrics.maximumHeight)
    }

    private var isAtBottom: Bool {
      let visibleRect = contentView.documentVisibleRect
      return visibleRect.maxY >= outputTextView.bounds.maxY - 0.5
    }

    private func attributedText(_ text: String, foreground: NSColor) -> NSAttributedString {
      let paragraph = NSMutableParagraphStyle()
      paragraph.minimumLineHeight = metrics.rowHeight
      paragraph.maximumLineHeight = metrics.rowHeight
      return NSAttributedString(
        string: text,
        attributes: [
          .font: metrics.font,
          .foregroundColor: foreground,
          .paragraphStyle: paragraph,
        ]
      )
    }

    private func measureContent(text: String) {
      guard let layoutManager = outputTextView.layoutManager,
        let textContainer = outputTextView.textContainer
      else { return }
      layoutManager.ensureLayout(for: textContainer)
      let used = layoutManager.usedRect(for: textContainer)
      let contentWidth = max(
        1,
        ceil(metrics.horizontalPadding + used.maxX + metrics.trailingPadding)
      )
      let lineCount =
        text.utf8.reduce(into: 1) { count, byte in
          if byte == 0x0A { count += 1 }
        }
      contentFittingSize = CGSize(
        width: contentWidth,
        height: max(
          metrics.rowHeight + (metrics.verticalPadding * 2),
          ceil(max(used.maxY, CGFloat(lineCount) * metrics.rowHeight))
            + (metrics.verticalPadding * 2)
        )
      )
    }

    private func fitDocument(toViewportSize viewportSize: CGSize) {
      let documentSize = CGSize(
        width: max(viewportSize.width, contentFittingSize.width),
        height: contentFittingSize.height
      )
      if outputTextView.frame.size != documentSize {
        outputTextView.setFrameSize(documentSize)
      }
      let scrollsHorizontally = contentFittingSize.width > viewportSize.width + 0.5
      if hasHorizontalScroller != scrollsHorizontally {
        hasHorizontalScroller = scrollsHorizontally
      }
      let scrollsVertically = contentFittingSize.height > viewportSize.height + 0.5
      if hasVerticalScroller != scrollsVertically {
        hasVerticalScroller = scrollsVertically
      }
      reflectScrolledClipView(contentView)
    }

    private func scrollToBottom() {
      let bottomY = max(0, contentFittingSize.height - visibleContentHeight)
      contentView.scroll(to: CGPoint(x: contentView.bounds.minX, y: bottomY))
      reflectScrolledClipView(contentView)
    }
  }

  private struct NativePlainOutputMetrics {
    let font = NSFont.monospacedSystemFont(
      ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
      weight: .regular
    )
    let horizontalPadding: CGFloat = 8
    let trailingPadding: CGFloat = 8
    let verticalPadding: CGFloat = 4

    var rowHeight: CGFloat {
      ceil(NSLayoutManager().defaultLineHeight(for: font)) + 2
    }
  }
#endif
