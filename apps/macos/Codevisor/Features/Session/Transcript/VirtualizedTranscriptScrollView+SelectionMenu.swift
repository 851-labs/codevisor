import CodevisorUI
import AppKit
import StreamMarkdown
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func transcriptSelectionMenu(for surface: NSTextView, with event: NSEvent) -> NSMenu? {
    guard initialPresentationGate.isReady,
      let surface = surface as? TranscriptSurfaceTextView,
      let point = selectionPoint(in: surface, atWindowPoint: event.locationInWindow)
    else { return nil }
    let isInSelection = transcriptSelection(contains: point)
    if !isInSelection, let menu = messageMenu(forRowKey: point.rowKey) {
      return menu
    }
    if !isInSelection {
      selectWord(at: point)
    }
    guard hasTranscriptSelection else { return nil }
    let menu = NSMenu()
    let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
    copyItem.target = self
    menu.addItem(copyItem)
    return menu
  }

  @objc func copy(_: Any?) {
    guard let text = selectedTranscriptText(), !text.isEmpty else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  override func selectAll(_: Any?) {
    guard let first = virtualLayout.keys.first, let last = virtualLayout.keys.last else { return }
    stopSelectionAutoScroll()
    textSelection.isDragging = false
    textSelection.granularity = .character
    textSelection.anchorRange = nil
    textSelection.endpointTexts = [:]
    textSelection.selection = TranscriptTextSelection(
      anchor: .rowStart(first),
      focus: .rowEnd(last)
    )
    applySelectionHighlights()
  }

  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copy(_:)):
      return hasTranscriptSelection
    case #selector(selectAll(_:)):
      return !virtualLayout.isEmpty
    default:
      return true
    }
  }

  private func selectWord(at point: TranscriptSelectionPoint) {
    stopSelectionAutoScroll()
    textSelection.isDragging = false
    takeFocusForSelection()
    replaceSelection(at: point, granularity: .word)
    cacheEndpointTexts()
    applySelectionHighlights()
  }

  private func transcriptSelection(contains point: TranscriptSelectionPoint) -> Bool {
    guard let span = resolvedSelectionSpan, !span.isEmpty else { return false }
    return !selectionPoint(point, precedes: span.start) && !selectionPoint(span.end, precedes: point)
  }
}
