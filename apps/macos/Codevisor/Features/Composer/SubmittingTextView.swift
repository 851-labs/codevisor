import AppKit
import CodevisorCore
import CodevisorUI
import TranscriptKit

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

  func allowQuoteBadgesOnly() {
    font = .preferredFont(forTextStyle: .body)
    isRichText = true
    importsGraphics = false
    usesFontPanel = false
    usesRuler = false
    typingAttributes = ChatInputEditor.textAttributes
  }

  func show(_ text: NSAttributedString) {
    textStorage?.setAttributedString(text)
    typingAttributes = ChatInputEditor.textAttributes
    revealSentText()
  }

  func insertQuote(_ quote: TranscriptQuote) {
    let edit = TranscriptQuotedPromptEdit.insertingQuote(quote, into: quotedPrompt, at: NSMaxRange(selectedRange()))
    replaceAsUndoableEdit(edit.range, with: ChatInputEditor.attributedText(edit.replacement))
    undoManager?.setActionName("Add Quote")
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

  private static let plainTextDragTypes: [NSPasteboard.PasteboardType] = [
    .string, NSPasteboard.PasteboardType("NSStringPboardType"),
  ]

  var acceptsDrops = true {
    didSet {
      guard acceptsDrops != oldValue else { return }
      updateDragTypeRegistration()
    }
  }

  override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
    [Self.quotedPromptType] + Self.plainTextDragTypes
  }

  override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
    [Self.quotedPromptType] + Self.plainTextDragTypes
  }

  override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [Self.quotedPromptType, .string] }

  override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    let selection = quotedPrompt.subprompt(in: selectedRange())
    switch type {
    case Self.quotedPromptType: return pboard.setString(selection.promptText, forType: type)
    case .string: return pboard.setString(selection.readableText, forType: type)
    default: return super.writeSelection(to: pboard, type: type)
    }
  }

  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
    guard type == Self.quotedPromptType, let promptText = pboard.string(forType: type) else {
      return super.readSelection(from: pboard, type: type)
    }

    let pasted = ChatInputEditor.attributedText(TranscriptQuotedPrompt(promptText: promptText))
    replaceAsUndoableEdit(rangeForUserTextChange, with: pasted)
    return true
  }

  private static let quotedPromptType = TranscriptQuotePasteboard.type

  override func updateDragTypeRegistration() {
    guard acceptsDrops else { return unregisterDraggedTypes() }
    super.updateDragTypeRegistration()
  }

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
