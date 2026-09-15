import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  /// The transcript owns focus instead of a text document, so AppKit's
  /// default key bindings have no document responder to perform scrolling.
  func handleKeyboardScroll(with event: NSEvent) -> Bool {
    // Navigation keys, including Fn-arrow equivalents, carry these flags.
    // Leave modified shortcuts to the responder chain.
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad, .capsLock])
    guard modifiers.isEmpty else { return false }

    let top = contentView.bounds.minY
    let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
    let line = max(1, verticalLineScroll)
    // The composer overlays the scroll view. Its spacer reserves the same
    // height at the bottom; exclude it from a page so no text gets skipped.
    let coveredHeight = rowByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey]?.estimatedHeight ?? 0
    let page = max(line, contentView.bounds.height - coveredHeight - verticalPageScroll)
    let requestedTop: CGFloat
    switch event.specialKey {
    case .home: requestedTop = 0
    case .pageUp: requestedTop = top - page
    case .end: requestedTop = maximum
    case .pageDown: requestedTop = top + page
    case .downArrow: requestedTop = top + line
    case .upArrow: requestedTop = top - line
    default: return false
    }
    guard initialPresentationGate.isReady else { return true }

    cancelDisclosureViewportAnchor()
    bottomJumpGate.cancel()
    lockedRestoreDistance = nil
    isHandlingUserInput = true
    markRecentUserInput()
    defer {
      isHandlingUserInput = false
      markRecentUserInput()
    }

    // Use the native bounds notification as user movement, just like the
    // wheel. setViewportTop would classify this as layout compensation and
    // suppress follow-state changes and history prefetching.
    let snapshotGeneration = viewportSnapshotGeneration
    contentView.scroll(to: CGPoint(x: 0, y: min(max(0, requestedTop), maximum)))
    reflectScrolledClipView(contentView)
    if viewportSnapshotGeneration == snapshotGeneration {
      viewportDidScroll()
    }
    // A page or document jump can leave the prepared row runway entirely.
    // Mount the destination now so the next paint has complete coverage.
    updateMountedRows()
    emitViewportSnapshot()
    return true
  }
}
