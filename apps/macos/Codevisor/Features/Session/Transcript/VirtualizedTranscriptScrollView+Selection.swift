import AppKit
import StreamMarkdown
import TranscriptKit

/// Mutable state of the transcript-wide text selection. It is a separate
/// object so the scroll view extension below can own the behavior without
/// needing stored properties.
@MainActor
final class TranscriptSelectionState {
  enum Granularity {
    case character, word, paragraph
  }

  typealias PointRange = (start: TranscriptSelectionPoint, end: TranscriptSelectionPoint)

  var selection: TranscriptTextSelection?
  var granularity: Granularity = .character
  /// The whole word or paragraph under a multi-click anchor. Dragging keeps
  /// the far edge of this range selected, as native text views do.
  var anchorRange: PointRange?
  var isDragging = false
  var lastDragLocationInWindow: NSPoint?
  var autoScrollTask: Task<Void, Never>?
  /// Raw surface text of the anchor and focus rows, captured while those rows
  /// were mounted. Copy stays offset-accurate after the virtualizer unmounts
  /// an endpoint row; interior rows only need their whole text.
  var endpointTexts: [String: [String]] = [:]
  var highlightedHostKeys: Set<String> = []
  var mouseDownMonitor: Any?
  var windowKeyObservers: [NSObjectProtocol] = []
}

// MARK: - Transcript-wide selection

/// One selection across every text surface in the transcript.
///
/// Rows are independent `NSTextView`s, so AppKit's own selection can never
/// leave the view a drag started in. The scroll view instead owns the
/// selection as `(row key, surface, offset)` endpoints, resolves them against
/// the virtual layout, and asks each mounted surface to paint its slice.
/// Hosts are recycled and rows unmount freely, so nothing here is keyed by
/// view identity; highlights are re-applied whenever the mounted set changes.
extension VirtualizedTranscriptScrollView: TranscriptSelectionCoordinating, NSUserInterfaceValidations {
  var hasTranscriptSelection: Bool {
    resolvedSelectionSpan.map { !$0.isEmpty } ?? false
  }

  var resolvedSelectionSpan: TranscriptSelectionSpan? {
    textSelection.selection?.resolve { virtualLayout.indexByKey[$0] }
  }

  // MARK: TranscriptSelectionCoordinating

  func beginTranscriptSelection(with event: NSEvent, in surface: NSTextView) -> Bool {
    guard initialPresentationGate.isReady,
      let surface = surface as? TranscriptSurfaceTextView,
      let point = selectionPoint(in: surface, atWindowPoint: event.locationInWindow)
    else { return false }
    startSelectionGesture(at: point, event: event)
    return true
  }

  /// A click on transcript whitespace, arriving through the document view.
  /// Starts a gesture anchored at the nearest text so a drag that begins in
  /// the margin still selects; a plain click there just clears.
  func beginTranscriptSelection(withDocumentClick event: NSEvent) -> Bool {
    guard initialPresentationGate.isReady else { return false }
    let documentPoint = transcriptDocumentView.convert(event.locationInWindow, from: nil)
    guard let point = selectionPoint(atDocumentPoint: documentPoint) else {
      clearTranscriptSelection()
      return false
    }
    startSelectionGesture(at: point, event: event)
    return true
  }

  func continueTranscriptSelection(with event: NSEvent) {
    guard textSelection.isDragging else { return }
    textSelection.lastDragLocationInWindow = event.locationInWindow
    updateSelectionFocus(toWindowPoint: event.locationInWindow)
  }

  func endTranscriptSelection(with event: NSEvent) {
    guard textSelection.isDragging else { return }
    textSelection.lastDragLocationInWindow = event.locationInWindow
    updateSelectionFocus(toWindowPoint: event.locationInWindow)
    textSelection.isDragging = false
    stopSelectionAutoScroll()
    if let span = resolvedSelectionSpan, span.isEmpty {
      clearTranscriptSelection()
    }
  }

  func clearTranscriptSelection() {
    stopSelectionAutoScroll()
    textSelection.isDragging = false
    textSelection.selection = nil
    textSelection.anchorRange = nil
    textSelection.endpointTexts = [:]
    applySelectionHighlights()
  }

  // MARK: Gesture

  private func startSelectionGesture(at point: TranscriptSelectionPoint, event: NSEvent) {
    takeFocusForSelection()
    let granularity: TranscriptSelectionState.Granularity =
      switch event.clickCount {
      case 0, 1: .character
      case 2: .word
      default: .paragraph
      }
    let extendsExisting =
      event.modifierFlags.contains(.shift)
      && granularity == .character
      && textSelection.selection != nil
    if extendsExisting, var selection = textSelection.selection {
      textSelection.granularity = .character
      textSelection.anchorRange = nil
      selection.focus = point
      textSelection.selection = selection
    } else {
      replaceSelection(at: point, granularity: granularity)
    }
    textSelection.isDragging = true
    textSelection.lastDragLocationInWindow = event.locationInWindow
    cacheEndpointTexts()
    applySelectionHighlights()
    startSelectionAutoScroll()
  }

  /// Anchors a fresh selection on the unit of text at `point`.
  func replaceSelection(
    at point: TranscriptSelectionPoint,
    granularity: TranscriptSelectionState.Granularity
  ) {
    let range = expandedRange(for: point, granularity: granularity)
    textSelection.granularity = granularity
    textSelection.anchorRange = range
    textSelection.selection = TranscriptTextSelection(anchor: range.start, focus: range.end)
    textSelection.endpointTexts = [:]
  }

  func takeFocusForSelection() {
    if let window, window.firstResponder !== self {
      window.makeFirstResponder(self)
    }
  }

  private func updateSelectionFocus(toWindowPoint windowPoint: NSPoint) {
    guard var selection = textSelection.selection else { return }
    var documentPoint = transcriptDocumentView.convert(windowPoint, from: nil)
    // Only the visible rows are guaranteed to be mounted; auto-scroll brings
    // the rest into the viewport and re-runs this.
    let visible = contentView.bounds
    documentPoint.y = min(max(documentPoint.y, visible.minY), max(visible.minY, visible.maxY - 1))
    guard let point = selectionPoint(atDocumentPoint: documentPoint) else { return }

    if textSelection.granularity != .character, let anchorRange = textSelection.anchorRange {
      let focusRange = expandedRange(for: point, granularity: textSelection.granularity)
      if selectionPoint(focusRange.start, precedes: anchorRange.start) {
        selection.anchor = anchorRange.end
        selection.focus = focusRange.start
      } else {
        selection.anchor = anchorRange.start
        selection.focus = focusRange.end
      }
    } else {
      selection.focus = point
    }
    guard selection != textSelection.selection else { return }
    textSelection.selection = selection
    cacheEndpointTexts()
    applySelectionHighlights()
  }

  func selectionPoint(
    _ lhs: TranscriptSelectionPoint,
    precedes rhs: TranscriptSelectionPoint
  ) -> Bool {
    guard let lhsRow = virtualLayout.indexByKey[lhs.rowKey],
      let rhsRow = virtualLayout.indexByKey[rhs.rowKey]
    else { return false }
    return (lhsRow, lhs.surface, lhs.offset) < (rhsRow, rhs.surface, rhs.offset)
  }

  func expandedRange(
    for point: TranscriptSelectionPoint,
    granularity: TranscriptSelectionState.Granularity
  ) -> TranscriptSelectionState.PointRange {
    guard granularity != .character,
      let surface = selectionSurface(at: point),
      let storage = surface.textStorage, storage.length > 0
    else { return (point, point) }
    // Derived from the text itself rather than `selectionRange(forProposedRange:granularity:)`,
    // which TextKit 2 views answer with a range running to the end of the text.
    let index = min(max(0, point.offset), storage.length)
    let range =
      switch granularity {
      case .word: storage.doubleClick(at: min(index, storage.length - 1))
      case .paragraph: (storage.string as NSString).paragraphRange(for: NSRange(location: index, length: 0))
      case .character: NSRange(location: index, length: 0)
      }
    return (
      TranscriptSelectionPoint(rowKey: point.rowKey, surface: point.surface, offset: range.location),
      TranscriptSelectionPoint(
        rowKey: point.rowKey, surface: point.surface, offset: NSMaxRange(range))
    )
  }

  func cacheEndpointTexts() {
    guard let selection = textSelection.selection else { return }
    var texts: [String: [String]] = [:]
    for key in [selection.anchor.rowKey, selection.focus.rowKey] {
      if let cached = textSelection.endpointTexts[key] {
        texts[key] = cached
      } else if let host = mountedHosts[key] {
        texts[key] = selectionSurfaces(in: host).map(\.string)
      }
    }
    textSelection.endpointTexts = texts
  }

  // MARK: Hit testing

  /// The row at a document-space y; see `VirtualTranscriptLayout.index(nearestToOffset:)`.
  func selectionRowIndex(atDocumentY y: CGFloat) -> Int? {
    virtualLayout.index(nearestToOffset: y - transcriptRowsOrigin)
  }

  func selectionPoint(atDocumentPoint documentPoint: NSPoint) -> TranscriptSelectionPoint? {
    guard let index = selectionRowIndex(atDocumentY: documentPoint.y) else { return nil }
    let key = virtualLayout.keys[index]
    guard let host = mountedHosts[key] else { return nil }
    let surfaces = selectionSurfaces(in: host)
    guard !surfaces.isEmpty else { return .rowStart(key) }
    let hostPoint = host.convert(documentPoint, from: transcriptDocumentView)
    for (surfaceIndex, surface) in surfaces.enumerated() {
      let frame = host.convert(surface.bounds, from: surface)
      if hostPoint.y < frame.minY {
        guard surfaceIndex > 0 else {
          return TranscriptSelectionPoint(rowKey: key, surface: 0, offset: 0)
        }
        return TranscriptSelectionPoint(
          rowKey: key,
          surface: surfaceIndex - 1,
          offset: surfaces[surfaceIndex - 1].transcriptTextLength
        )
      }
      if hostPoint.y <= frame.maxY {
        let viewPoint = surface.convert(documentPoint, from: transcriptDocumentView)
        return TranscriptSelectionPoint(
          rowKey: key,
          surface: surfaceIndex,
          offset: surface.transcriptCharacterIndex(at: viewPoint)
        )
      }
    }
    return TranscriptSelectionPoint(
      rowKey: key,
      surface: surfaces.count - 1,
      offset: surfaces[surfaces.count - 1].transcriptTextLength
    )
  }

  func selectionPoint(
    in surface: TranscriptSurfaceTextView,
    atWindowPoint windowPoint: NSPoint
  ) -> TranscriptSelectionPoint? {
    guard let (key, host) = mountedRowHost(containing: surface) else { return nil }
    let surfaces = selectionSurfaces(in: host)
    guard let surfaceIndex = surfaces.firstIndex(where: { $0 === surface }) else { return nil }
    let viewPoint = surface.convert(windowPoint, from: nil)
    return TranscriptSelectionPoint(
      rowKey: key,
      surface: surfaceIndex,
      offset: surface.transcriptCharacterIndex(at: viewPoint)
    )
  }

  private func mountedRowHost(containing view: NSView) -> (String, TranscriptMountedRowHost)? {
    var ancestor: NSView? = view
    while let current = ancestor {
      if let host = current as? TranscriptMountedRowHost {
        return mountedHosts.first { $0.value === host }.map { ($0.key, host) }
      }
      ancestor = current.superview
    }
    return nil
  }

  private func selectionSurface(at point: TranscriptSelectionPoint) -> TranscriptSurfaceTextView? {
    guard let host = mountedHosts[point.rowKey] else { return nil }
    let surfaces = selectionSurfaces(in: host)
    guard surfaces.indices.contains(point.surface) else { return nil }
    return surfaces[point.surface]
  }

  /// Every selectable text surface inside a mounted host, top to bottom.
  /// Both the settled AppKit renderer and SwiftUI-hosted rows nest their
  /// text views a few levels deep, so this walks the subtree; hosts are
  /// small and the walk only runs while a selection exists.
  func selectionSurfaces(in host: NSView) -> [TranscriptSurfaceTextView] {
    var found: [(view: TranscriptSurfaceTextView, frame: NSRect, order: Int)] = []
    func visit(_ view: NSView) {
      guard !view.isHidden else { return }
      if let surface = view as? TranscriptSurfaceTextView {
        guard surface.isSelectable, !surface.isEditable else { return }
        found.append((surface, host.convert(surface.bounds, from: surface), found.count))
        return
      }
      for child in view.subviews { visit(child) }
    }
    visit(host)
    return
      found
      .sorted { lhs, rhs in
        (lhs.frame.minY.rounded(), lhs.frame.minX.rounded(), lhs.order)
          < (rhs.frame.minY.rounded(), rhs.frame.minX.rounded(), rhs.order)
      }
      .map(\.view)
  }

  // MARK: Highlights

  /// Pushes the current selection into every mounted surface. Cheap when
  /// nothing is selected; otherwise bounded by the mounted window.
  func applySelectionHighlights() {
    var span = resolvedSelectionSpan
    if textSelection.selection != nil, span == nil {
      // An endpoint row left the layout (its message was re-projected).
      textSelection.selection = nil
      textSelection.anchorRange = nil
      textSelection.endpointTexts = [:]
    }
    if span?.isEmpty == true, !textSelection.isDragging { span = nil }

    var highlightedKeys: Set<String> = []
    for (key, host) in mountedHosts {
      if let span, let index = virtualLayout.indexByKey[key], span.contains(rowIndex: index) {
        let surfaces = selectionSurfaces(in: host)
        let ranges = span.surfaceRanges(
          rowIndex: index,
          surfaceLengths: surfaces.map(\.transcriptTextLength)
        )
        for (surface, range) in zip(surfaces, ranges) {
          surface.transcriptSelectionHighlight = range.map { NSRange($0) }
        }
        highlightedKeys.insert(key)
      } else if textSelection.highlightedHostKeys.contains(key) {
        clearSelectionHighlights(in: host)
      }
    }
    textSelection.highlightedHostKeys = highlightedKeys
  }

  /// Mount and refresh passes call this on every scroll frame; it is a
  /// no-op unless a selection exists.
  func refreshSelectionHighlightsIfNeeded() {
    if textSelection.selection != nil {
      applySelectionHighlights()
    }
  }

  func clearSelectionHighlights(in host: NSView) {
    for surface in selectionSurfaces(in: host) {
      surface.transcriptSelectionHighlight = nil
    }
  }

  /// Called when a host leaves the mounted set. Recycled hosts must never
  /// carry a highlight into their next row.
  func selectionHostWillDetach(_ host: TranscriptMountedRowHost, key: String) {
    guard textSelection.highlightedHostKeys.remove(key) != nil else { return }
    clearSelectionHighlights(in: host)
  }

  // MARK: Copy

  func selectedTranscriptText() -> String? {
    guard let span = resolvedSelectionSpan, !span.isEmpty else { return nil }
    enum Source {
      case mounted([TranscriptSurfaceTextView])
      case text([String])
    }
    var sources: [Int: Source] = [:]
    func source(_ index: Int) -> Source {
      if let cached = sources[index] { return cached }
      let key = virtualLayout.keys[index]
      let resolved: Source
      if let host = mountedHosts[key] {
        resolved = .mounted(selectionSurfaces(in: host))
      } else if let cached = textSelection.endpointTexts[key] {
        resolved = .text(cached)
      } else if let row = rowByKey[key] {
        resolved = .text(
          TranscriptRowTextProjection.surfaceTexts(for: row, theme: markdownRowStyle.markdown))
      } else {
        resolved = .text([])
      }
      sources[index] = resolved
      return resolved
    }

    return TranscriptSelectionText.text(
      in: span,
      surfaceLengths: { index in
        switch source(index) {
        case let .mounted(surfaces): surfaces.map(\.transcriptTextLength)
        case let .text(texts): texts.map { ($0 as NSString).length }
        }
      },
      substring: { index, surface, range in
        switch source(index) {
        case let .mounted(surfaces):
          surfaces[surface].transcriptPlainText(in: NSRange(range))
        case let .text(texts):
          TranscriptSelectionText.substring(of: texts[surface], in: range)
        }
      },
      rowSeparator: { index in
        // Leaf rows of one fragmented list or quote are laid out flush;
        // everything else reads as separate paragraphs.
        guard index > 0, let previous = rowByKey[virtualLayout.keys[index - 1]] else {
          return "\n\n"
        }
        return previous.spacingAfter == 0 ? "\n" : "\n\n"
      }
    )
  }

  // MARK: Auto-scroll

  private func startSelectionAutoScroll() {
    guard textSelection.autoScrollTask == nil else { return }
    textSelection.autoScrollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(16))
        guard !Task.isCancelled, let self else { return }
        self.selectionAutoScrollTick()
      }
    }
  }

  func stopSelectionAutoScroll() {
    textSelection.autoScrollTask?.cancel()
    textSelection.autoScrollTask = nil
  }

  private func selectionAutoScrollTick() {
    guard textSelection.isDragging, let windowPoint = textSelection.lastDragLocationInWindow else {
      stopSelectionAutoScroll()
      return
    }
    let documentPoint = transcriptDocumentView.convert(windowPoint, from: nil)
    let visible = contentView.bounds
    let overshoot: CGFloat
    if documentPoint.y < visible.minY {
      overshoot = documentPoint.y - visible.minY
    } else if documentPoint.y > visible.maxY {
      overshoot = documentPoint.y - visible.maxY
    } else {
      return
    }
    let magnitude = min(48, max(4, abs(overshoot) * 0.3))
    scrollForSelection(by: overshoot < 0 ? -magnitude : magnitude)
    updateSelectionFocus(toWindowPoint: windowPoint)
  }

  /// A selection drag past the viewport edge is user scrolling: it clears
  /// restore locks and follow intent exactly like a wheel event.
  private func scrollForSelection(by delta: CGFloat) {
    let maximumTop = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
    var origin = contentView.bounds.origin
    let target = min(maximumTop, max(0, origin.y + delta))
    guard abs(target - origin.y) > 0.01 else { return }
    origin.y = target
    cancelDisclosureViewportAnchor()
    bottomJumpGate.cancel()
    lockedRestoreDistance = nil
    isHandlingUserInput = true
    markRecentUserInput()
    contentView.scroll(to: origin)
    reflectScrolledClipView(contentView)
    updateMountedRows()
    emitViewportSnapshot()
    isHandlingUserInput = false
    markRecentUserInput()
  }

  // MARK: Focus and clicks elsewhere

  /// Clicks that never reach a surface or the document view — SwiftUI rows
  /// swallow their own mouse events — still dismiss the selection.
  func installSelectionMouseMonitor() {
    guard textSelection.mouseDownMonitor == nil else { return }
    textSelection.mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) {
      [weak self] event in
      self?.selectionMonitorObservedMouseDown(event)
      return event
    }
    // The highlight color follows key-window status, like a native selection.
    let center = NotificationCenter.default
    textSelection.windowKeyObservers = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
    ].map { name in
      center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.redrawSelectionHighlights() }
      }
    }
  }

  func uninstallSelectionMouseMonitor() {
    if let monitor = textSelection.mouseDownMonitor {
      NSEvent.removeMonitor(monitor)
    }
    textSelection.mouseDownMonitor = nil
    for observer in textSelection.windowKeyObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    textSelection.windowKeyObservers = []
  }

  private func redrawSelectionHighlights() {
    for key in textSelection.highlightedHostKeys {
      guard let host = mountedHosts[key] else { continue }
      for surface in selectionSurfaces(in: host) where surface.transcriptSelectionHighlight != nil {
        surface.needsDisplay = true
      }
    }
  }

  private func selectionMonitorObservedMouseDown(_ event: NSEvent) {
    guard textSelection.selection != nil, let window, event.window === window,
      let hit = window.contentView?.hitTest(event.locationInWindow),
      hit.isDescendant(of: self)
    else { return }
    // Surfaces and the document view start their own gesture; a scroller
    // drag is not a click on content.
    if hit is TranscriptSurfaceTextView || hit is NSScroller || hit === transcriptDocumentView {
      return
    }
    clearTranscriptSelection()
  }
}

extension TranscriptSurfaceTextView {
  fileprivate var transcriptTextLength: Int { textStorage?.length ?? 0 }

  fileprivate func transcriptCharacterIndex(at viewPoint: NSPoint) -> Int {
    let index = characterIndexForInsertion(at: viewPoint)
    guard index != NSNotFound else { return 0 }
    return min(max(0, index), transcriptTextLength)
  }
}
