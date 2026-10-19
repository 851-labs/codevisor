import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func handleKeyboardScroll(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad, .capsLock])
    guard modifiers.isEmpty else { return false }

    let top = contentView.bounds.minY
    let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
    let line = max(1, verticalLineScroll)
    let page = max(line, unobstructedViewport.height - verticalPageScroll)
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

    let snapshotGeneration = viewportSnapshotGeneration
    contentView.scroll(to: CGPoint(x: 0, y: min(max(0, requestedTop), maximum)))
    reflectScrolledClipView(contentView)
    if viewportSnapshotGeneration == snapshotGeneration {
      viewportDidScroll()
    }
    updateMountedRows()
    emitViewportSnapshot()
    return true
  }
}
