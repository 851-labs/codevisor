#if canImport(UIKit) && !canImport(AppKit)
  import StreamMarkdown
  import SwiftUI
  import UIKit

  struct IOSNativePlainOutputView: UIViewRepresentable {
    let text: String
    let theme: Theme
    let followsTail: Bool

    func makeUIView(context _: Context) -> IOSNativePlainOutputScrollView {
      let scrollView = IOSNativePlainOutputScrollView()
      scrollView.setContent(text: text, theme: theme, followsTail: followsTail)
      return scrollView
    }

    func updateUIView(_ scrollView: IOSNativePlainOutputScrollView, context _: Context) {
      scrollView.setContent(text: text, theme: theme, followsTail: followsTail)
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize,
      uiView scrollView: IOSNativePlainOutputScrollView,
      context _: Context
    ) -> CGSize? {
      let width =
        proposal.width.flatMap { $0.isFinite ? $0 : nil }
        ?? scrollView.contentFittingSize.width
      return scrollView.fitContent(toViewportWidth: max(1, width))
    }
  }

  @MainActor
  final class IOSNativePlainOutputScrollView: UIScrollView {
    private(set) var outputTextView: UITextView
    private(set) var contentFittingSize = CGSize(width: 1, height: 1)

    private let metrics = IOSNativePlainOutputMetrics()
    private var renderedText: String?
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
      outputTextView = UITextView(frame: .zero, textContainer: textContainer)

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

      outputTextView.isEditable = false
      outputTextView.isSelectable = true
      outputTextView.isScrollEnabled = false
      outputTextView.backgroundColor = .clear
      outputTextView.textContainer.lineFragmentPadding = 0
      outputTextView.textContainerInset = UIEdgeInsets(
        top: metrics.verticalPadding,
        left: metrics.horizontalPadding,
        bottom: metrics.verticalPadding,
        right: 0
      )
      outputTextView.adjustsFontForContentSizeCategory = true
      addSubview(outputTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    func setContent(text: String, theme: Theme, followsTail: Bool) {
      guard renderedText != text || renderedTheme != theme else { return }

      let shouldFollowTail = followsTail && (renderedText == nil || isAtBottom)
      let oldText = renderedText
      let oldTheme = renderedTheme
      let selection = outputTextView.selectedRange
      let foreground = UIColor(theme.textPrimary)

      outputTextView.textStorage.beginEditing()
      if let oldText, oldTheme == theme, text.hasPrefix(oldText) {
        let suffix = String(text.dropFirst(oldText.count))
        if !suffix.isEmpty {
          outputTextView.textStorage.append(attributedText(suffix, foreground: foreground))
        }
      } else {
        outputTextView.textStorage.setAttributedString(
          attributedText(text, foreground: foreground)
        )
      }
      outputTextView.textStorage.endEditing()
      renderedText = text
      renderedTheme = theme

      let length = outputTextView.textStorage.length
      outputTextView.selectedRange = NSRange(
        location: min(selection.location, length),
        length: min(selection.length, max(0, length - min(selection.location, length)))
      )

      measureContent(text: text)
      fitDocument(
        toViewportSize: CGSize(width: max(bounds.width, 1), height: visibleContentHeight)
      )
      if shouldFollowTail { scrollToBottom() }
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

    private var isAtBottom: Bool {
      contentOffset.y + bounds.height >= contentSize.height - 0.5
    }

    private func attributedText(_ text: String, foreground: UIColor) -> NSAttributedString {
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
      let layoutManager = outputTextView.layoutManager
      let textContainer = outputTextView.textContainer
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
        outputTextView.frame = CGRect(origin: .zero, size: documentSize)
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

    private func scrollToBottom() {
      let bottomY = max(0, contentFittingSize.height - visibleContentHeight)
      setContentOffset(CGPoint(x: contentOffset.x, y: bottomY), animated: false)
    }
  }

  private struct IOSNativePlainOutputMetrics {
    let font = UIFont.scaledMonospacedSystemFont(forTextStyle: .caption1)
    let horizontalPadding: CGFloat = 8
    let trailingPadding: CGFloat = 8
    let verticalPadding: CGFloat = 4

    var rowHeight: CGFloat { ceil(font.lineHeight) + 2 }
  }
#endif
