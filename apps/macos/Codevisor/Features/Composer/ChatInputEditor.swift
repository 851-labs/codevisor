import AppKit
import CodevisorCore
import SwiftUI

enum ComposerKeyCommand {
  case moveSelectionUp
  case moveSelectionDown
  case acceptSelection
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
    NSLayoutManager().defaultLineHeight(
      for: NSFont.preferredFont(forTextStyle: .body)
    ) + verticalTextInset * 2
  }

  @Binding var text: String
  @Binding var calculatedHeight: CGFloat
  var selection: Binding<NSRange>? = nil
  var minHeight: CGFloat = Self.singleLineHeight
  var maxHeight: CGFloat = 240
  var topBleed: CGFloat = 0
  var onSubmit: () -> Void
  var onQueueSubmit: (() -> Bool)? = nil
  var onKeyCommand: ((ComposerKeyCommand) -> Bool)? = nil
  var onPasteAttachments: (([PastedAttachment]) -> Bool)? = nil
  var onTextViewReady: ((SubmittingTextView) -> Void)? = nil
  @Environment(\.isEnabled) private var isEnabled

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
    textView.string = text
    textView.font = .preferredFont(forTextStyle: .body)
    textView.isRichText = false
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
    DispatchQueue.main.async { recalculateHeight(textView) }
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
    if textView.string != text {
      if textView.hasMarkedText() {
        textView.inputContext?.discardMarkedText()
        textView.unmarkText()
      }
      textView.string = text
    }
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

  private func recalculateHeight(_ textView: NSTextView, synchronously: Bool = false) {
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
    let clamped = min(max(used, minHeight), maxHeight)
    if abs(clamped - calculatedHeight) > 0.5 {
      if synchronously {
        calculatedHeight = clamped
      } else {
        DispatchQueue.main.async { calculatedHeight = clamped }
      }
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ChatInputEditor
    weak var textView: SubmittingTextView?
    var isApplyingUpdate = false
    private var measuredText: String?
    private var measuredWidth: CGFloat = -1

    init(_ parent: ChatInputEditor) { self.parent = parent }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func recalculateHeightIfNeeded() {
      guard let textView else { return }
      let width = textView.bounds.width
      guard measuredText != textView.string || abs(measuredWidth - width) > 0.5 else { return }
      recordMeasurement(textView)
      parent.recalculateHeight(textView)
    }

    @objc func textViewFrameDidChange(_ notification: Notification) {
      guard let textView else { return }
      guard abs(measuredWidth - textView.bounds.width) > 0.5 else { return }
      recordMeasurement(textView)
      parent.recalculateHeight(textView)
    }

    private func recordMeasurement(_ textView: NSTextView) {
      measuredText = textView.string
      measuredWidth = textView.bounds.width
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      recordMeasurement(textView)
      parent.text = textView.string
      parent.recalculateHeight(textView, synchronously: true)
    }

    func markedTextDidChange() {
      guard !isApplyingUpdate, let textView, parent.text != textView.string else { return }
      recordMeasurement(textView)
      parent.text = textView.string
      parent.recalculateHeight(textView, synchronously: true)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard !isApplyingUpdate, let selection = parent.selection, let textView else { return }
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
        return parent.onKeyCommand?(.acceptSelection) == true
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

extension NSTextView {
  func replaceAsUndoableEdit(_ range: NSRange, with replacement: String) {
    breakUndoCoalescing()
    guard shouldChangeText(in: range, replacementString: replacement) else { return }
    textStorage?.replaceCharacters(in: range, with: replacement)
    didChangeText()
    breakUndoCoalescing()
    setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
  }
}

final class SubmittingTextView: NSTextView {
  var onWindowChanged: (() -> Void)?
  var onMarkedTextChange: (() -> Void)?
  private var sentTextReveal: DispatchWorkItem?

  func hideSentText() {
    guard !string.isEmpty, sentTextReveal == nil else { return }
    alphaValue = 0
    let reveal = DispatchWorkItem { [weak self] in self?.revealSentText() }
    sentTextReveal = reveal
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reveal)
  }

  private func revealSentText() {
    guard let reveal = sentTextReveal else { return }
    reveal.cancel()
    sentTextReveal = nil
    alphaValue = 1
  }

  override var string: String {
    didSet { revealSentText() }
  }

  override func didChangeText() {
    super.didChangeText()
    revealSentText()
  }

  override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    onMarkedTextChange?()
  }

  override func unmarkText() {
    super.unmarkText()
    onMarkedTextChange?()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    onWindowChanged?()
  }

  var onSubmit: (() -> Void)?
  var onQueueSubmit: (() -> Bool)?
  var onKeyCommand: ((ComposerKeyCommand) -> Bool)?
  var onPasteAttachments: (([PastedAttachment]) -> Bool)?

  override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

  private static let blockedFormatActions: Set<Selector> = [
    #selector(NSText.alignLeft(_:)),
    #selector(NSText.alignCenter(_:)),
    #selector(NSText.alignRight(_:)),
    #selector(NSTextView.alignJustified(_:)),
    #selector(NSText.underline(_:)),
    #selector(NSTextView.outline(_:)),
    #selector(NSTextView.raiseBaseline(_:)),
    #selector(NSTextView.lowerBaseline(_:)),
    NSSelectorFromString("superscript:"),
    NSSelectorFromString("subscript:"),
    NSSelectorFromString("unscript:"),
    #selector(NSTextView.changeFont(_:)),
    NSSelectorFromString("changeAttributes:"),
  ]

  override func alignLeft(_ sender: Any?) {}
  override func alignCenter(_ sender: Any?) {}
  override func alignRight(_ sender: Any?) {}
  override func alignJustified(_ sender: Any?) {}
  override func underline(_ sender: Any?) {}
  override func outline(_ sender: Any?) {}
  override func raiseBaseline(_ sender: Any?) {}
  override func lowerBaseline(_ sender: Any?) {}
  override func changeFont(_ sender: Any?) {}

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if let action = item.action, Self.blockedFormatActions.contains(action) {
      return false
    }
    if item.action == #selector(paste(_:)),
      isEditable,
      onPasteAttachments != nil,
      Self.pasteboardContainsAttachments(NSPasteboard.general)
    {
      return true
    }
    return super.validateUserInterfaceItem(item)
  }

  override func paste(_ sender: Any?) {
    let pasteboard = NSPasteboard.general
    if let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) as? [URL], !urls.isEmpty {
      if onPasteAttachments?(urls.map { .fileURL($0) }) == true {
        return
      }
      super.paste(sender)
      return
    }
    if let data = pasteboard.data(forType: .png) {
      if onPasteAttachments?([.image(data: data, suggestedName: nil)]) == true {
        return
      }
    } else if let onPasteAttachments, let tiff = pasteboard.data(forType: .tiff) {
      Task {
        let png = await Task.detached(priority: .userInitiated) {
          pngData(from: tiff)
        }.value
        guard let png else { return }
        _ = onPasteAttachments([.image(data: png, suggestedName: nil)])
      }
      return
    }
    super.paste(sender)
  }

  private static func pasteboardContainsAttachments(_ pasteboard: NSPasteboard) -> Bool {
    if pasteboard.canReadObject(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: true]
    ) {
      return true
    }
    return pasteboard.availableType(from: [.png, .tiff]) != nil
  }

  enum EdgeLine { case first, last }

  func isCaretOnEdgeLine(_ edge: EdgeLine) -> Bool {
    let selection = selectedRange()
    guard selection.length == 0, !hasMarkedText() else { return false }
    let length = (string as NSString).length
    guard length > 0 else { return true }
    guard let layoutManager, let textContainer else { return false }
    layoutManager.ensureLayout(for: textContainer)
    let caretRect = firstLineFragment(at: selection.location, layoutManager: layoutManager)
    let edgeRect = firstLineFragment(
      at: edge == .first ? 0 : length,
      layoutManager: layoutManager
    )
    return abs(caretRect.minY - edgeRect.minY) < 0.5
  }

  private func firstLineFragment(at location: Int, layoutManager: NSLayoutManager) -> NSRect {
    let length = (string as NSString).length
    if location >= length, layoutManager.extraLineFragmentTextContainer != nil {
      return layoutManager.extraLineFragmentRect
    }
    let characterIndex = min(location, max(length - 1, 0))
    let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
    return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
  }

  override func keyDown(with event: NSEvent) {
    if hasMarkedText() {
      super.keyDown(with: event)
      return
    }
    if event.keyCode == 53, onKeyCommand?(.dismissSelection) == true {
      return
    }
    if event.keyCode == 36 || event.keyCode == 76 {
      guard isEditable else { return }
      handleReturn(event)
      return
    }
    super.keyDown(with: event)
  }

  private func handleReturn(_ event: NSEvent) {
    switch Self.returnAction(for: event) {
    case .insertNewline:
      super.keyDown(with: event)
    case .queue:
      if onQueueSubmit?() != true { submitOrAcceptSelection() }
    case .send:
      submitOrAcceptSelection()
    }
  }

  private func submitOrAcceptSelection() {
    if onKeyCommand?(.acceptSelection) != true {
      onSubmit?()
    }
  }

  private static func returnAction(for event: NSEvent) -> ComposerReturnAction {
    let modifiers = event.modifierFlags
    return ComposerReturnAction(
      shift: modifiers.contains(.shift),
      option: modifiers.contains(.option),
      command: modifiers.contains(.command)
    )
  }
}
