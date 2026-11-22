#if canImport(UIKit) && !canImport(AppKit)
  import QuartzCore
  import SwiftUI
  import UIKit

  public struct SelectableTextView: UIViewRepresentable {
    private let attributedText: NSAttributedString
    private let fillsWidth: Bool
    private let streamingAnimation: StreamingTextAnimationContext?
    @Environment(\.markdownLinkAction) private var linkAction
    @Environment(\.textQuoteAction) private var quoteAction
    @Environment(\.textCopyAction) private var copyAction
    @Environment(\.textSelectionSession) private var selectionSession
    @Environment(\.streamingTextAnimationFrameClock) private var animationFrameClock
    @Environment(\.streamMarkdownTextLayoutWidth) private var rowLayoutWidth

    public init(attributedText: NSAttributedString, fillsWidth: Bool = true) {
      self.attributedText = attributedText
      self.fillsWidth = fillsWidth
      streamingAnimation = nil
    }

    init(
      attributedText: NSAttributedString,
      fillsWidth: Bool = true,
      streamingAnimation: StreamingTextAnimationContext?
    ) {
      self.attributedText = attributedText
      self.fillsWidth = fillsWidth
      self.streamingAnimation = streamingAnimation
    }

    public func makeCoordinator() -> Coordinator {
      Coordinator()
    }

    public func makeUIView(context: Context) -> SelectableTextKitView {
      let view = SelectableTextKitView()
      view.animationFrameClock = animationFrameClock
      context.coordinator.linkAction = linkAction
      context.coordinator.quoteAction = quoteAction
      view.copyAction = copyAction
      view.delegate = context.coordinator
      view.selectionSession = selectionSession
      let prepared = context.coordinator.preparedText(
        for: attributedText,
        animation: streamingAnimation
      )
      view.setContent(
        prepared.text,
        latestAnimationEnd: prepared.latestAnimationEnd,
        activeAnimationRanges: prepared.activeAnimationRanges
      )
      layOutAtDisplayedWidth(view, text: prepared.text, context: context)
      return view
    }

    public func updateUIView(_ textView: SelectableTextKitView, context: Context) {
      textView.animationFrameClock = animationFrameClock
      context.coordinator.linkAction = linkAction
      context.coordinator.quoteAction = quoteAction
      textView.copyAction = copyAction
      textView.selectionSession = selectionSession
      let prepared = context.coordinator.preparedText(
        for: attributedText,
        animation: streamingAnimation
      )
      textView.setContent(
        prepared.text,
        latestAnimationEnd: prepared.latestAnimationEnd,
        activeAnimationRanges: prepared.activeAnimationRanges
      )
      layOutAtDisplayedWidth(textView, text: prepared.text, context: context)
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

    private func layOutAtDisplayedWidth(
      _ view: SelectableTextKitView,
      text: NSAttributedString,
      context: Context
    ) {
      guard
        let width = StreamMarkdownTextLayout.displayedWidth(
          currentWidth: view.frame.width,
          rowLayoutWidth: rowLayoutWidth,
          fillsWidth: fillsWidth,
          naturalWidth: context.coordinator.measurer.naturalWidth(for: text)
        )
      else { return }
      _ = view.contentHeight(forWidth: width)
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
      var quoteAction: TextQuoteAction?
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

      public func textViewDidChangeSelection(_ textView: UITextView) {
        guard let view = textView as? SelectableTextKitView, let session = view.selectionSession,
          session.isActive, view.isFirstResponder, view.selectedRange.length == 0
        else { return }
        session.end()
      }

      public func textView(
        _ textView: UITextView,
        primaryActionFor textItem: UITextItem,
        defaultAction: UIAction
      ) -> UIAction? {
        guard let url = Self.linkURL(of: textItem, in: textView), let linkAction else {
          return defaultAction
        }
        return linkAction.activate(url, in: textView, at: textItem.range.location) ? UIAction { _ in } : defaultAction
      }

      private static func linkURL(of textItem: UITextItem, in textView: UITextView) -> URL? {
        switch textItem.content {
        case let .link(url):
          return url
        case .textAttachment:
          let location = textItem.range.location
          guard location < textView.attributedText.length else { return nil }
          let link = textView.attributedText.attribute(.link, at: location, effectiveRange: nil)
          return link as? URL ?? (link as? String).flatMap(URL.init(string:))
        default:
          return nil
        }
      }

      public func textView(
        _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
      ) -> UIMenu? {
        textQuoteEditMenu(in: textView, range: range, suggestedActions: suggestedActions, action: quoteAction)
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
