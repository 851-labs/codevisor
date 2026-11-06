import AppKit
import CodevisorCore
import CodevisorUI
import StreamMarkdown
import TranscriptKit

@MainActor
final class TranscriptQuoteState {
  var addButton: TranscriptAddToChatButton?
  let addButtonTiming = TranscriptAddToChatShowTiming()
  let highlight = TranscriptQuoteHighlightView()
  let notFoundNotice = TranscriptQuoteNotFoundNotice()
  var pendingReveal: TranscriptQuote?
  var revealGeneration = 0
  var viewportHoldDeadline: TimeInterval = 0
}

extension VirtualizedTranscriptScrollView {
  private static let viewportHoldWindow: TimeInterval = 1

  var addToChatMenuItem: NSMenuItem {
    let item = NSMenuItem(title: "Add to Chat", action: #selector(addSelectionToChat), keyEquivalent: "")
    item.target = self
    MenuItemImage.show("text.quote", on: item)
    return item
  }

  @objc func addSelectionToChat() {
    guard let quote = selectedQuote() else { return }
    holdViewportForComposerChange()
    sessionController?.addQuote(quote)
    clearTranscriptSelection()
  }

  func showAddToChatButton(afterMouseUp event: NSEvent, draggedSelection: Bool) {
    let pointer = event.locationInWindow
    quotes.addButtonTiming.show(afterClickCount: event.clickCount, draggedSelection: draggedSelection) {
      [weak self] in self?.showAddToChatButtonIfNeeded(nearWindowPoint: pointer)
    }
  }

  func showAddToChatButtonIfNeeded(nearWindowPoint pointer: NSPoint? = nil) {
    guard hasTranscriptSelection, sessionController != nil,
      let placement = addToChatButtonPlacement(nearWindowPoint: pointer)
    else { return hideAddToChatButton() }

    let button = installedAddToChatButton()
    button.show(at: placement.origin(for: button.fittingSize))
  }

  func holdViewportForComposerChange() {
    quotes.viewportHoldDeadline = ProcessInfo.processInfo.systemUptime + Self.viewportHoldWindow
  }

  var holdsViewportForComposerChange: Bool {
    ProcessInfo.processInfo.systemUptime <= quotes.viewportHoldDeadline
  }

  func releaseFollowIfOffBottom() {
    guard followsLatest, currentDistanceFromBottom() > Self.atBottomThreshold else { return }
    followsLatest = false
    onFollowStateChange?(false)
  }

  func hideAddToChatButton() {
    quotes.addButtonTiming.cancel()
    quotes.addButton?.hide()
  }

  func isAddToChatButton(_ view: NSView) -> Bool {
    guard let button = quotes.addButton else { return false }
    return view.isDescendant(of: button)
  }

  func documentRects(for selection: TranscriptTextSelection) -> [NSRect] {
    guard let span = selection.resolve(rowIndex: { virtualLayout.indexByKey[$0] }) else { return [] }

    return span.rowRange.flatMap { rowIndex -> [NSRect] in
      guard let host = mountedHosts[virtualLayout.keys[rowIndex]] else { return [] }
      let surfaces = selectionSurfaces(in: host)
      let ranges = span.surfaceRanges(rowIndex: rowIndex, surfaceLengths: surfaces.map(\.transcriptTextLength))
      return zip(surfaces, ranges).flatMap { surface, range in
        range.map { documentRects(of: NSRange($0), in: surface) } ?? []
      }
    }
  }

  private func selectionDocumentRects() -> [NSRect] {
    guard let selection = textSelection.selection else { return [] }
    return documentRects(for: selection)
  }

  private func documentRects(of range: NSRange, in surface: any TranscriptTextSurface) -> [NSRect] {
    surface.transcriptTextRects(for: range)
      .map { transcriptDocumentView.convert($0, from: surface) }
      .filter { $0.width > 0 && $0.height > 0 }
  }

  private func selectedQuote() -> TranscriptQuote? {
    guard let span = resolvedSelectionSpan, let text = selectedTranscriptText(), !text.isEmpty else { return nil }

    let sourceRow = span.rowRange.lazy
      .compactMap { self.rowByKey[self.virtualLayout.keys[$0]] }
      .first { TranscriptQuote.messageID(forRowKey: $0.layoutKey) != nil }
    return sourceRow.flatMap { TranscriptQuote(text: text, row: $0) }
  }

  private func installedAddToChatButton() -> TranscriptAddToChatButton {
    let button =
      quotes.addButton
      ?? TranscriptAddToChatButton(shortcut: addToChatShortcut) { [weak self] in self?.addSelectionToChat() }
    quotes.addButton = button
    transcriptDocumentView.addSubview(button, positioned: .above, relativeTo: nil)
    return button
  }

  private func addToChatButtonPlacement(nearWindowPoint pointer: NSPoint?) -> AddToChatButtonPlacement? {
    AddToChatButtonPlacement(
      lineRects: selectionDocumentRects(),
      pointer: pointer.map { transcriptDocumentView.convert($0, from: nil) },
      bounds: unobstructedViewport
    )
  }
}
