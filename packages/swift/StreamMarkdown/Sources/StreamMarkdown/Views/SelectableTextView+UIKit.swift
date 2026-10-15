#if canImport(UIKit) && !canImport(AppKit)
  import QuartzCore
  import SwiftUI
  import UIKit

  public struct SelectableTextView: UIViewRepresentable {
    private let attributedText: NSAttributedString
    private let fillsWidth: Bool
    private let streamingAnimation: StreamingTextAnimationContext?
    private let isSelecting: Binding<Bool>?
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.streamingTextAnimationFrameClock) private var animationFrameClock
    @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth

    public init(attributedText: NSAttributedString, fillsWidth: Bool = true) {
      self.attributedText = attributedText
      self.fillsWidth = fillsWidth
      streamingAnimation = nil
      isSelecting = nil
    }

    public init(attributedText: NSAttributedString, fillsWidth: Bool = true, isSelecting: Binding<Bool>) {
      self.attributedText = attributedText
      self.fillsWidth = fillsWidth
      streamingAnimation = nil
      self.isSelecting = isSelecting
    }

    init(
      attributedText: NSAttributedString,
      fillsWidth: Bool = true,
      streamingAnimation: StreamingTextAnimationContext?
    ) {
      self.attributedText = attributedText
      self.fillsWidth = fillsWidth
      self.streamingAnimation = streamingAnimation
      isSelecting = nil
    }

    public func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    public func makeUIView(context: Context) -> SelectableTextKitView {
      let view = SelectableTextKitView()
      view.animationFrameClock = animationFrameClock
      context.coordinator.linkAction = linkAction
      context.coordinator.isSelecting = isSelecting
      view.delegate = context.coordinator
      view.selectionEnded = { [weak coordinator = context.coordinator] in coordinator?.endSelection() }
      let prepared = context.coordinator.preparedText(
        for: attributedText,
        animation: streamingAnimation
      )
      view.setContent(
        prepared.text,
        latestAnimationEnd: prepared.latestAnimationEnd,
        activeAnimationRanges: prepared.activeAnimationRanges
      )
      _ = view.contentHeight(
        forWidth: resolvedWidth(for: prepared.text, proposalWidth: nil, context: context)
      )
      if let isSelecting {
        view.setSelecting(isSelecting.wrappedValue)
      }
      return view
    }

    public func updateUIView(_ textView: SelectableTextKitView, context: Context) {
      textView.animationFrameClock = animationFrameClock
      context.coordinator.linkAction = linkAction
      context.coordinator.isSelecting = isSelecting
      let prepared = context.coordinator.preparedText(
        for: attributedText,
        animation: streamingAnimation
      )
      textView.setContent(
        prepared.text,
        latestAnimationEnd: prepared.latestAnimationEnd,
        activeAnimationRanges: prepared.activeAnimationRanges
      )
      _ = textView.contentHeight(
        forWidth: resolvedWidth(for: prepared.text, proposalWidth: nil, context: context)
      )
      if let isSelecting {
        textView.setSelecting(isSelecting.wrappedValue)
      }
    }

    public func sizeThatFits(
      _ proposal: ProposedViewSize,
      uiView: SelectableTextKitView,
      context: Context
    ) -> CGSize? {
      let prepared = context.coordinator.preparedText(
        for: attributedText,
        animation: streamingAnimation
      )
      uiView.setContent(
        prepared.text,
        latestAnimationEnd: prepared.latestAnimationEnd,
        activeAnimationRanges: prepared.activeAnimationRanges
      )
      let text = prepared.text
      let width = resolvedWidth(
        for: text,
        proposalWidth: proposal.width,
        context: context
      )
      return CGSize(
        width: width,
        height: uiView.contentHeight(forWidth: width)
      )
    }

    private func resolvedWidth(
      for text: NSAttributedString,
      proposalWidth: CGFloat?,
      context: Context
    ) -> CGFloat {
      StreamMarkdownTextLayout.resolvedWidth(
        proposalWidth: proposalWidth,
        rowLayoutWidth: rowLayoutWidth,
        fillsWidth: fillsWidth,
        naturalWidth: context.coordinator.measurer.naturalWidth(for: text)
      )
    }

    @MainActor
    public final class Coordinator: NSObject, UITextViewDelegate {
      fileprivate lazy var measurer = UIKitTextKitTextMeasurer()
      var linkAction: MarkdownLinkAction?
      var isSelecting: Binding<Bool>?
      private let animationState = StreamingTextAnimationState()
      private var attributedInput: NSAttributedString?
      private var stableAttributedText: NSAttributedString?
      private var preparedInput: NSAttributedString?
      private var preparedSourceID: String?
      private var preparedDocumentSource: String?
      private var preparedIsStreaming = false
      private var preparedAnimatesInitialContent = false
      private var preparedReduceMotion = false
      private var preparedPlaybackRevision = 0
      private var prepared: PreparedStreamingText?

      fileprivate func preparedText(
        for input: NSAttributedString,
        animation: StreamingTextAnimationContext?
      ) -> PreparedStreamingText {
        let text: NSAttributedString
        if attributedInput === input, let stableAttributedText {
          text = stableAttributedText
        } else if let stableAttributedText, stableAttributedText.isEqual(to: input) {
          attributedInput = input
          text = stableAttributedText
        } else {
          attributedInput = input
          stableAttributedText = input
          text = input
        }

        if preparedInput === text,
          preparedSourceID == animation?.sourceID,
          preparedDocumentSource == animation?.documentSource,
          preparedIsStreaming == (animation?.isStreaming ?? false),
          preparedAnimatesInitialContent == (animation?.animatesInitialContent ?? false),
          preparedReduceMotion == (animation?.reduceMotion ?? false),
          preparedPlaybackRevision == (animation?.playbackRevision ?? 0),
          let prepared
        {
          return prepared
        }

        let value = animationState.prepare(text, context: animation)
        preparedInput = text
        preparedSourceID = animation?.sourceID
        preparedDocumentSource = animation?.documentSource
        preparedIsStreaming = animation?.isStreaming ?? false
        preparedAnimatesInitialContent = animation?.animatesInitialContent ?? false
        preparedReduceMotion = animation?.reduceMotion ?? false
        preparedPlaybackRevision = animation?.playbackRevision ?? 0
        prepared = value
        return value
      }

      func endSelection() {
        guard let isSelecting, isSelecting.wrappedValue else { return }
        isSelecting.wrappedValue = false
      }

      public func textViewDidChangeSelection(_ textView: UITextView) {
        guard let view = textView as? SelectableTextKitView, view.isSelectingOnDemand,
          view.isFirstResponder, view.selectedRange.length == 0
        else { return }
        endSelection()
      }

      public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
      ) -> UIAction? {
        guard case let .link(url) = textItem.content, let linkAction else {
          return defaultAction
        }
        return linkAction.activate(url, in: textView, at: textItem.range.location) ? UIAction { _ in } : defaultAction
      }

      public func textView(
        _ textView: UITextView,
        menuConfigurationFor textItem: UITextItem,
        defaultMenu: UIMenu
      ) -> UITextItem.MenuConfiguration? {
        markdownImageMenuConfiguration(
          in: textView, for: textItem, defaultMenu: defaultMenu, action: linkAction)
      }
    }
  }

  @MainActor
  public final class SelectableTextKitView: UITextView, StreamingTextAnimationFrameClient,
    @MainActor UIEditMenuInteractionDelegate
  {
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
    fileprivate var isSelectingOnDemand = false
    fileprivate var selectionEnded: (() -> Void)?
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

    fileprivate func setSelecting(_ selecting: Bool) {
      guard selecting != isSelectingOnDemand || selecting != isSelectable else { return }
      isSelectingOnDemand = selecting
      isSelectable = selecting
      guard selecting, textStorage.length > 0 else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isSelectingOnDemand, self.window != nil else { return }
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
      if resigned, isSelectingOnDemand {
        selectionEnded?()
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
      for range in activeAnimationRanges where NSMaxRange(range) <= textStorage.length {
        guard
          let fade = textStorage.attribute(
            .streamMarkdownFade,
            at: range.location,
            effectiveRange: nil
          ) as? StreamingTextFadeMetadata
        else { continue }
        guard
          includesCompletedRanges
            || fade.animationEndTime > time
        else { continue }
        layoutManager.invalidateDisplay(forCharacterRange: range)
        let glyphs = layoutManager.glyphRange(
          forCharacterRange: range,
          actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerInset.left
        rect.origin.y += textContainerInset.top
        setNeedsDisplay(rect.insetBy(dx: -2, dy: -2))
      }
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

  @MainActor
  final class UIKitTextKitTextMeasurer {
    private let storage = NSTextStorage()
    private let layoutManager = UIKitStreamingTextLayoutManager()
    private let container = NSTextContainer(
      size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private var measuredText: NSAttributedString?
    private var naturalWidthText: NSAttributedString?
    private var cachedNaturalWidth: CGFloat = 1

    init() {
      storage.addLayoutManager(layoutManager)
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      layoutManager.addTextContainer(container)
    }

    func naturalWidth(for text: NSAttributedString) -> CGFloat {
      if naturalWidthText === text { return cachedNaturalWidth }
      if measuredText !== text {
        storage.setAttributedString(text)
        measuredText = text
      }
      container.size = CGSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude)
      layoutManager.ensureLayout(for: container)
      naturalWidthText = text
      cachedNaturalWidth = max(1, ceil(layoutManager.usedRect(for: container).width))
      return cachedNaturalWidth
    }
  }
#endif
