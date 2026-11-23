import AppKit
import CodevisorCore
import StreamMarkdown
import CodevisorUI
import SwiftUI
import TranscriptKit

enum ComposerKeyCommand {
  case moveSelectionUp
  case moveSelectionDown
  case acceptSelection
  case holdSelection
  case dismissSelection
  case recallPreviousPrompt
  case recallNextPrompt
}

enum PastedAttachment {
  case fileURL(URL)
  case image(data: Data, suggestedName: String?)
}

struct ChatInputEditor: NSViewRepresentable {
  private static let verticalTextInset: CGFloat = 6

  static var singleLineHeight: CGFloat {
    BodyTextMetrics.lineHeight + verticalTextInset * 2
  }

  static var textAttributes: [NSAttributedString.Key: Any] {
    [.font: NSFont.preferredFont(forTextStyle: .body), .foregroundColor: NSColor.labelColor]
  }

  @Binding var content: TranscriptQuotedPrompt
  @Binding var calculatedHeight: CGFloat
  var selection: Binding<NSRange>? = nil
  var undo: ComposerUndoHistories? = nil
  var minHeight: CGFloat = Self.singleLineHeight
  var maxHeight: CGFloat = 240
  var topBleed: CGFloat = 0
  var onSubmit: () -> Void
  var onQueueSubmit: (() -> Bool)? = nil
  var onKeyCommand: ((ComposerKeyCommand) -> Bool)? = nil
  var onPasteAttachments: (([PastedAttachment]) -> Bool)? = nil
  var onTextViewReady: ((SubmittingTextView) -> Void)? = nil
  var quoteInsertions: [TranscriptQuote] = []
  var onQuotesInserted: ((Set<String>) -> Void)? = nil
  var onOpenQuote: ((TranscriptQuote) -> Void)? = nil
  @Environment(\.isEnabled) private var isEnabled
  @Environment(WorkspaceActivity.self) private var workspaceActivity: WorkspaceActivity?

  func makeNSView(context: Context) -> NSScrollView {
    let textView = SubmittingTextView()
    textView.delegate = context.coordinator
    textView.onMarkedTextChange = { [weak coordinator = context.coordinator] in
      coordinator?.markedTextDidChange()
    }
    textView.onSubmit = { onSubmit() }
    textView.onQueueSubmit = onQueueSubmit
    textView.onKeyCommand = onKeyCommand
    textView.onPasteAttachments = onPasteAttachments
    onTextViewReady?(textView)
    textView.allowQuoteBadgesOnly()
    textView.show(Self.attributedText(content))
    textView.writingToolsBehavior = .none
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 0, height: Self.verticalTextInset)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0

    let scroll = NSScrollView()
    let clipView = GrowingTextClipView()
    clipView.maximumGrowingHeight = maxHeight
    scroll.contentView = clipView
    scroll.drawsBackground = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: topBleed, left: 0, bottom: 0, right: 0)
    scroll.hasVerticalScroller = false
    scroll.hasHorizontalScroller = false
    scroll.documentView = textView
    clipView.scroll(to: NSPoint(x: 0, y: -topBleed))
    context.coordinator.textView = textView
    textView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.textViewFrameDidChange(_:)),
      name: NSView.frameDidChangeNotification,
      object: textView
    )
    context.coordinator.scheduleHeightUpdate()
    return scroll
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? SubmittingTextView else { return }
    context.coordinator.parent = self
    context.coordinator.isApplyingUpdate = true
    defer { context.coordinator.isApplyingUpdate = false }
    textView.onSubmit = { onSubmit() }
    textView.onQueueSubmit = onQueueSubmit
    textView.onKeyCommand = onKeyCommand
    textView.onPasteAttachments = onPasteAttachments
    textView.isEditable = isEnabled
    textView.acceptsDrops = workspaceActivity?.isActive ?? true
    if let clipView = scrollView.contentView as? GrowingTextClipView {
      clipView.maximumGrowingHeight = maxHeight
    }
    let previousBleed = scrollView.contentInsets.top
    if previousBleed != topBleed {
      let clipView = scrollView.contentView
      let wasAtTop = clipView.bounds.minY <= -previousBleed + 0.5
      scrollView.contentInsets = NSEdgeInsets(top: topBleed, left: 0, bottom: 0, right: 0)
      if wasAtTop {
        clipView.scroll(to: NSPoint(x: 0, y: -topBleed))
        scrollView.reflectScrolledClipView(clipView)
      }
    }
    let changedChat = context.coordinator.adopt(undo?.history(for: textView), in: textView, showing: content)
    if textView.quotedPrompt != content {
      if textView.hasMarkedText() {
        textView.inputContext?.discardMarkedText()
        textView.unmarkText()
      }
      textView.show(Self.attributedText(content))
      if !changedChat { context.coordinator.forgetUndoHistory() }
    }
    context.coordinator.insert(quoteInsertions)
    if let selection, !textView.hasMarkedText() {
      let length = (textView.string as NSString).length
      let location = min(selection.wrappedValue.location, length)
      let clamped = NSRange(
        location: location,
        length: min(selection.wrappedValue.length, length - location)
      )
      if textView.selectedRange() != clamped {
        textView.setSelectedRange(clamped)
      }
    }
    context.coordinator.recalculateHeightIfNeeded()
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  static func attributedText(_ prompt: TranscriptQuotedPrompt) -> NSAttributedString {
    TranscriptQuoteBadgeText.attributedString(prompt, attributes: textAttributes)
  }

  private func applyFittingHeight(of textView: NSTextView) {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
    let visibleLimit = NSRect(x: 0, y: 0, width: container.size.width, height: maxHeight + 1)
    layoutManager.ensureLayout(forBoundingRect: visibleLimit, in: container)
    let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
    let clamped = min(max(used, minHeight), maxHeight)
    if abs(clamped - calculatedHeight) > 0.5 {
      calculatedHeight = clamped
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ChatInputEditor
    weak var textView: SubmittingTextView?
    var isApplyingUpdate = false
    private var measuredRevision: Int?
    private var measuredWidth: CGFloat = -1
    private var isHeightUpdateScheduled = false

    private var undo: ComposerUndoHistory?
    private var insertedQuoteIDs: Set<String> = []

    init(_ parent: ChatInputEditor) { self.parent = parent }

    func adopt(
      _ undo: ComposerUndoHistory?, in textView: SubmittingTextView, showing content: TranscriptQuotedPrompt
    ) -> Bool {
      guard self.undo !== undo else { return false }

      self.undo?.leave(showing: textView.quotedPrompt.promptText)
      textView.breakUndoCoalescing()
      self.undo = undo
      undo?.enter(showing: content.promptText)
      return true
    }

    func insert(_ quotes: [TranscriptQuote]) {
      let fresh = quotes.filter { !insertedQuoteIDs.contains($0.id) }
      guard !fresh.isEmpty else { return }

      insertedQuoteIDs.formUnion(fresh.map(\.id))
      Task { @MainActor [weak self] in self?.insertNow(fresh) }
    }

    private func insertNow(_ quotes: [TranscriptQuote]) {
      let ids = Set(quotes.map(\.id))
      guard let textView, textView.isEditable else {
        insertedQuoteIDs.subtract(ids)
        return
      }

      textView.insertQuotes(quotes)
      parent.onQuotesInserted?(ids)
    }

    func forgetUndoHistory() {
      undo?.forget()
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
      undo?.manager ?? view.window?.undoManager
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func recalculateHeightIfNeeded() {
      guard let textView else { return }
      let width = textView.bounds.width
      guard measuredRevision != textView.quotedText.revision || abs(measuredWidth - width) > 0.5 else { return }
      recordMeasurement(textView)
      scheduleHeightUpdate()
    }

    func scheduleHeightUpdate() {
      guard !isHeightUpdateScheduled else { return }
      isHeightUpdateScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        isHeightUpdateScheduled = false
        guard let textView else { return }
        parent.applyFittingHeight(of: textView)
      }
    }

    @objc func textViewFrameDidChange(_ notification: Notification) {
      guard let textView else { return }
      guard abs(measuredWidth - textView.bounds.width) > 0.5 else { return }
      recordMeasurement(textView)
      scheduleHeightUpdate()
    }

    private func recordMeasurement(_ textView: NSTextView) {
      measuredRevision = (textView as? SubmittingTextView)?.quotedText.revision
      measuredWidth = textView.bounds.width
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? SubmittingTextView else { return }
      recordMeasurement(textView)
      parent.content = textView.quotedPrompt
      parent.applyFittingHeight(of: textView)
    }

    func markedTextDidChange() {
      guard !isApplyingUpdate, let textView, parent.content != textView.quotedPrompt else { return }
      recordMeasurement(textView)
      parent.content = textView.quotedPrompt
      parent.applyFittingHeight(of: textView)
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
      toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]
    ) -> [NSAttributedString.Key: Any] {
      ChatInputEditor.textAttributes
    }

    func textView(
      _ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int
    ) {
      guard let badge = cell.attachment as? TranscriptQuoteBadgeAttachment else { return }
      parent.onOpenQuote?(badge.quote)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isApplyingUpdate, let selection = parent.selection, let textView else { return }
      if textView.quotedText.isStale { parent.content = textView.quotedPrompt }
      let range = textView.selectedRange()
      if selection.wrappedValue != range {
        selection.wrappedValue = range
      }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.moveUp(_:)):
        if parent.onKeyCommand?(.moveSelectionUp) == true { return true }
        guard let textView = textView as? SubmittingTextView,
          textView.isCaretOnEdgeLine(.first)
        else { return false }
        return parent.onKeyCommand?(.recallPreviousPrompt) == true
      case #selector(NSResponder.moveDown(_:)):
        if parent.onKeyCommand?(.moveSelectionDown) == true { return true }
        guard let textView = textView as? SubmittingTextView,
          textView.isCaretOnEdgeLine(.last)
        else { return false }
        return parent.onKeyCommand?(.recallNextPrompt) == true
      case #selector(NSResponder.insertTab(_:)):
        if parent.onKeyCommand?(.acceptSelection) != true { textView.window?.selectNextKeyView(nil) }
        return true
      case #selector(NSResponder.insertBacktab(_:)):
        if parent.onKeyCommand?(.holdSelection) != true { textView.window?.selectPreviousKeyView(nil) }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        return parent.onKeyCommand?(.dismissSelection) == true
      default:
        return false
      }
    }
  }
}

private final class GrowingTextClipView: NSClipView {
  var maximumGrowingHeight: CGFloat = 0

  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var bounds = super.constrainBoundsRect(proposedBounds)
    guard maximumGrowingHeight > 0,
      let documentView,
      documentView.frame.height <= maximumGrowingHeight + 0.5
    else {
      return bounds
    }
    bounds.origin.y =
      documentView.isFlipped
      ? -contentInsets.top
      : max(0, documentView.frame.height - bounds.height)
    return bounds
  }
}
