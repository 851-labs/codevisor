import AppKit
import CodevisorUI
import Observation
import StreamMarkdown
import SwiftUI
import TranscriptKit

@MainActor
final class TranscriptBotBubbleRowHost: TranscriptMountedRowHost {
  private static let trailingClearance: CGFloat = 64
  private let bubble = TranscriptBubbleBackgroundView()
  private let anchor = UserBubbleAnchorView()
  private let markdownView = SettledMarkdownView()
  private var content: TranscriptBotMessageContent?
  private var style: TranscriptMarkdownRowStyle?
  private var measuredWidth: CGFloat = -1
  private var reportedHeight: CGFloat?
  private var presentationReady = false
  private(set) var messageID = ""

  override var isFlipped: Bool { true }
  override var isPresentationReady: Bool { presentationReady }
  override var needsRunwayPreparation: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    installVerticalClipMask()
    addSubview(bubble)
    bubble.addSubview(anchor)
    addSubview(markdownView)
    markdownView.onContentHeightChange = { [weak self] in
      self?.requestContentMeasurement()
    }
    setAccessibilityCustomActions([
      NSAccessibilityCustomAction(name: "Copy") { [weak self] in
        self?.copyText() ?? false
      }
    ])
    observeMenuHighlight()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setContent(
    _ content: TranscriptBotMessageContent,
    messageID: String,
    style: TranscriptMarkdownRowStyle,
    linkAction: MarkdownLinkAction?,
    imageLoader: MarkdownImageLoader,
    knownHeight: CGFloat?
  ) {
    self.content = content
    self.messageID = messageID
    self.style = style
    markdownView.setContent(
      blocks: content.blocks, theme: style.markdown, streamID: messageID, linkAction: linkAction,
      imageLoader: imageLoader)
    bubble.isHighlighted = TranscriptMessageMenuHighlight.shared.messageID == messageID
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
    if abs(max(1, bounds.width) - measuredWidth) > 0.25 {
      _ = syncContentWidth()
    }
  }

  private func measureAndLayout() {
    guard let content, let style else { return }

    let insets = TranscriptSendFlightGeometry.bubbleTextInsets
    let natural = TranscriptBotMessageWidth.natural(of: content, theme: style.markdown)
    let textWidth = max(1, min(natural, bounds.width - Self.trailingClearance))
    let textHeight = markdownView.contentHeight(forWidth: textWidth)
    let height = ceil(textHeight + insets.vertical * 2)
    bubble.frame = NSRect(x: 0, y: 0, width: ceil(textWidth + insets.horizontal * 2), height: height)
    bubble.cornerRadius = UserBubbleBackground.cornerRadius(for: .large)
    anchor.frame = bubble.bounds
    markdownView.frame = NSRect(x: insets.horizontal, y: insets.vertical, width: textWidth, height: textHeight)
    report(height)
  }

  private func report(_ height: CGFloat) {
    let previous = reportedHeight
    let becameReady = !presentationReady && markdownView.isContentReady
    reportedHeight = height
    presentationReady = markdownView.isContentReady
    guard becameReady || previous.map({ abs($0 - height) > 0.5 }) ?? true else { return }

    onHeightChange?(height)
  }

  private func copyText() -> Bool {
    guard let text = content?.copyText, !text.isEmpty else { return false }

    NSPasteboard.general.clearContents()
    return NSPasteboard.general.setString(text, forType: .string)
  }

  private func observeMenuHighlight() {
    let highlighted = withObservationTracking {
      TranscriptMessageMenuHighlight.shared.messageID == messageID
    } onChange: { [weak self] in
      Task { @MainActor in self?.observeMenuHighlight() }
    }
    bubble.isHighlighted = highlighted
  }
}
