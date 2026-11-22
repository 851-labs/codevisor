#if canImport(UIKit) && !canImport(AppKit)
  import QuartzCore
  import SwiftUI
  import UIKit

  @MainActor
  public final class SelectableTextKitView: UITextView, StreamingTextAnimationFrameClient,
    @MainActor UIEditMenuInteractionDelegate
  {
    var copyAction: TextCopyAction?

    public override func copy(_ sender: Any?) {
      guard let copied = selectedAttributedText, copyAction?.copy(copied) == true else { return super.copy(sender) }
    }

    private var selectedAttributedText: NSAttributedString? {
      let range = selectedRange
      guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return nil }
      return textStorage.attributedSubstring(from: range)
    }

    public convenience init(attributedText: NSAttributedString) {
      self.init(preparedLayout: nil)
      setContent(attributedText)
    }

    private var representedText: NSAttributedString?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 1
    private var latestAnimationEnd: TimeInterval?
    private var activeAnimationRanges: [NSRange] = []
    private var animationDisplayLink: CADisplayLink?
    private var selectionMenuInteraction: UIEditMenuInteraction?
    public var animationFrameClock: StreamingTextAnimationFrameClock? {
      didSet {
        guard animationFrameClock !== oldValue else { return }
        oldValue?.remove(self)
        stopAnimation()
        updateAnimation(until: latestAnimationEnd)
      }
    }

    init(preparedLayout: PreparedNativeTextLayout? = nil) {
      let textStorage = preparedLayout?.storage ?? NSTextStorage()
      let layoutManager = preparedLayout?.manager ?? UIKitStreamingTextLayoutManager()
      let textContainer =
        preparedLayout?.container
        ?? NSTextContainer(
          size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
      if preparedLayout == nil {
        textStorage.addLayoutManager(layoutManager)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)
      }

      super.init(frame: CGRect(origin: .zero, size: preparedLayout?.size ?? .zero), textContainer: textContainer)
      if let preparedLayout {
        representedText = preparedLayout.text
        measuredWidth = preparedLayout.size.width
        measuredHeight = preparedLayout.size.height
      }
      isEditable = false
      isSelectable = true
      isScrollEnabled = false
      isOpaque = false
      backgroundColor = .clear
      textContainerInset = .zero
      adjustsFontForContentSizeCategory = true
      dataDetectorTypes = []
      linkTextAttributes = [.foregroundColor: UIColor.link]
      setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    weak var selectionSession: TextSelectionSession? {
      didSet {
        guard selectionSession !== oldValue else { return }
        oldValue?.leave(self)
        selectionSession?.join(self)
        isSelectable = selectionSession?.isActive ?? true
      }
    }

    func setContent(
      _ text: NSAttributedString,
      latestAnimationEnd: TimeInterval? = nil,
      activeAnimationRanges: [NSRange] = []
    ) {
      self.activeAnimationRanges = activeAnimationRanges
      updateAnimation(until: latestAnimationEnd)
      guard representedText !== text else {
        redrawActiveStreamingText(at: CACurrentMediaTime())
        return
      }
      if let representedText, representedText.isEqual(to: text) {
        self.representedText = text
        redrawActiveStreamingText(at: CACurrentMediaTime())
        return
      }

      let selection = selectedRange
      let previousText = representedText
      representedText = text
      measuredWidth = -1
      if let previousText,
        text.length >= previousText.length,
        text.string.hasPrefix(previousText.string),
        previousText.isEqual(
          to: text.attributedSubstring(
            from: NSRange(location: 0, length: previousText.length)
          ))
      {
        textStorage.append(
          text.attributedSubstring(
            from: NSRange(
              location: previousText.length,
              length: text.length - previousText.length
            ))
        )
      } else {
        textStorage.setAttributedString(text)
      }
      let location = min(selection.location, text.length)
      let length = min(selection.length, text.length - location)
      selectedRange = NSRange(location: location, length: length)
      setNeedsDisplay()
    }

    func focusSelection() {
      guard textStorage.length > 0 else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.selectionSession?.isActive == true, self.window != nil else { return }
        self.becomeFirstResponder()
        self.selectAll(nil)
        self.presentSelectionMenu()
      }
    }

    private func presentSelectionMenu() {
      guard let bounds = selectionBounds else { return }
      let interaction = selectionMenuInteraction ?? UIEditMenuInteraction(delegate: self)
      if selectionMenuInteraction == nil {
        addInteraction(interaction)
        selectionMenuInteraction = interaction
      }
      interaction.presentEditMenu(
        with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY)))
    }

    private var selectionBounds: CGRect? {
      guard let range = selectedTextRange else { return nil }
      let bounds = selectionRects(for: range).map(\.rect).reduce(CGRect.null) { $0.union($1) }
      return bounds.isNull ? nil : bounds
    }

    public func editMenuInteraction(
      _ interaction: UIEditMenuInteraction,
      targetRectFor configuration: UIEditMenuConfiguration
    ) -> CGRect {
      selectionBounds ?? .null
    }

    public override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned {
        selectionSession?.memberResigned()
      }
      return resigned
    }

    public override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        stopAnimation()
      } else {
        updateAnimation(until: latestAnimationEnd)
      }
    }

    private func updateAnimation(until endTime: TimeInterval?) {
      latestAnimationEnd = endTime
      let now = CACurrentMediaTime()
      streamingLayoutManager?.animationTime = now
      if let animationFrameClock {
        stopAnimation()
        animationFrameClock.update(self, until: endTime)
        return
      }
      guard let endTime, endTime > now else {
        stopAnimation()
        return
      }
      guard window != nil, animationDisplayLink == nil else { return }
      let link = CADisplayLink(target: self, selector: #selector(animationFrame(_:)))
      link.add(to: .main, forMode: .common)
      animationDisplayLink = link
    }

    @objc private func animationFrame(_ displayLink: CADisplayLink) {
      let isFinal = latestAnimationEnd.map { displayLink.timestamp >= $0 } ?? true
      streamingTextAnimationFrame(at: displayLink.timestamp, isFinal: isFinal)
      if isFinal {
        stopAnimation()
      }
    }

    public func streamingTextAnimationFrame(at timestamp: TimeInterval, isFinal: Bool) {
      streamingLayoutManager?.animationTime = timestamp
      redrawActiveStreamingText(
        at: timestamp,
        includesCompletedRanges: isFinal
      )
    }

    private func stopAnimation() {
      animationDisplayLink?.invalidate()
      animationDisplayLink = nil
    }

    private var streamingLayoutManager: UIKitStreamingTextLayoutManager? {
      layoutManager as? UIKitStreamingTextLayoutManager
    }

    private func redrawActiveStreamingText(
      at time: TimeInterval,
      includesCompletedRanges: Bool = false
    ) {
      guard
        let range = StreamingFadeRedrawRange.union(
          of: activeAnimationRanges, in: textStorage, at: time, includesCompletedRanges: includesCompletedRanges)
      else { return }

      layoutManager.invalidateDisplay(forCharacterRange: range)
      let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
      var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
      rect.origin.x += textContainerInset.left
      rect.origin.y += textContainerInset.top
      setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
    }

    func contentHeight(forWidth width: CGFloat) -> CGFloat {
      let width = max(1, width)
      if abs(measuredWidth - width) <= 0.25 {
        return measuredHeight
      }
      if abs(bounds.width - width) > 0.25 {
        bounds.size.width = width
      }
      textContainer.size = CGSize(
        width: width,
        height: CGFloat.greatestFiniteMagnitude
      )
      layoutManager.ensureLayout(for: textContainer)
      measuredWidth = width
      measuredHeight = max(1, ceil(layoutManager.usedRect(for: textContainer).height))
      return measuredHeight
    }
  }
#endif
