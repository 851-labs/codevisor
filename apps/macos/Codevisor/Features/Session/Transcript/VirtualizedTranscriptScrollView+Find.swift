import AppKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

/// Mutable find-in-chat state, kept apart from the scroll view so the
/// extension below can own the behavior without stored properties.
@MainActor
final class TranscriptFindState {
  /// What a mounted row's highlights were computed from. A native Markdown
  /// host whose stamp is unchanged keeps its highlights, so scrolling and
  /// streaming do not re-search rows that did not change.
  struct HighlightStamp: Equatable {
    let query: String
    let currentOrdinal: Int?
    let host: ObjectIdentifier
    let content: TranscriptVirtualRow.Content
  }

  let engine = TranscriptFindEngine()
  weak var model: TranscriptFindModel?
  var highlightStamps: [String: HighlightStamp] = [:]
  /// Bumped by every navigation so a late follow-up pass from an earlier
  /// jump never moves the viewport.
  var revealGeneration = 0
}

// MARK: - Find in chat

/// Find counts matches on a background index (see `TranscriptFindEngine`),
/// so matches in unmounted history count and can be navigated to without
/// the main thread scanning the transcript. Only mounted rows paint
/// highlights, and mount passes re-apply them because hosts are recycled.
extension VirtualizedTranscriptScrollView: TranscriptFindTarget {
  /// The height the floating find bar covers at the top of the viewport.
  private static let findBarClearance: CGFloat = 60

  func attachFindModel(_ model: TranscriptFindModel) {
    find.model = model
    model.target = self
    find.engine.onRefresh = { [weak self] in
      self?.findResultsDidChange(reveal: false)
    }
  }

  func transcriptFindQueryDidChange(_ model: TranscriptFindModel) {
    guard model.isPresented else { return }
    // Typing more of a word keeps the bar on the match it is already on
    // when that one still matches; a fresh search starts at the viewport.
    let startRow =
      find.engine.results.current.flatMap { current in
        rows.firstIndex { $0.layoutKey == current.rowKey }
      } ?? firstVisibleRowIndex()
    let search = find.engine.search(
      model.query,
      rows: rows,
      firstVisibleRow: startRow,
      theme: markdownRowStyle.markdown
    )
    if model.query.isEmpty {
      findResultsDidChange(reveal: false)
      find.engine.prepare(rows: rows, theme: markdownRowStyle.markdown)
      return
    }
    Task { [weak self] in
      guard await search.value else { return }
      self?.findResultsDidChange(reveal: true)
    }
  }

  func transcriptFind(_ model: TranscriptFindModel, step delta: Int) {
    guard find.engine.isActive else { return }
    // While a search is still counting, the step is applied to its results
    // and revealed when they arrive.
    if find.engine.step(by: delta) {
      findResultsDidChange(reveal: true)
    }
  }

  func transcriptFindDidDismiss(_ model: TranscriptFindModel) {
    find.revealGeneration &+= 1
    find.engine.clear()
    findResultsDidChange(reveal: false)
    // Like a browser, closing the bar hands the keyboard back to the page.
    if let window, window.firstResponder !== self {
      window.makeFirstResponder(self)
    }
  }

  private func findResultsDidChange(reveal: Bool) {
    find.model?.publish(find.engine.results)
    applyFindHighlights()
    if reveal { revealCurrentFindMatch() }
  }

  // MARK: Rows

  /// Streaming and pagination change the rows under an open find bar. The
  /// engine re-counts in the background, one pass at a time.
  func scheduleFindRefreshIfNeeded() {
    find.engine.refresh(rows: rows, theme: markdownRowStyle.markdown)
  }

  private func firstVisibleRowIndex() -> Int {
    guard
      let index = virtualLayout.index(
        nearestToOffset: contentView.bounds.minY - transcriptRowsOrigin
      ),
      virtualLayout.keys.indices.contains(index)
    else { return 0 }
    let key = virtualLayout.keys[index]
    return rows.firstIndex { $0.layoutKey == key } ?? 0
  }

  // MARK: Highlights

  func refreshFindHighlightsIfNeeded() {
    if find.engine.isActive || !find.highlightStamps.isEmpty {
      applyFindHighlights()
    }
  }

  /// Pushes the matches into every mounted searchable row. Each row's
  /// surfaces are searched as displayed, which keeps the painted ranges
  /// exact even where a surface's text differs from the projection.
  func applyFindHighlights() {
    var stamps: [String: TranscriptFindState.HighlightStamp] = [:]
    if find.engine.isActive {
      let query = find.engine.query
      for (key, host) in mountedHosts {
        guard let row = rowByKey[key], row.findableBlocks != nil else { continue }
        let stamp = TranscriptFindState.HighlightStamp(
          query: query,
          currentOrdinal: find.engine.results.currentOrdinal(inRow: key),
          host: ObjectIdentifier(host),
          content: row.content
        )
        stamps[key] = stamp
        // SwiftUI-hosted rows (a response still streaming) can create or
        // replace their text views between passes; only native hosts are
        // stable enough to skip.
        if host is TranscriptMarkdownRowHost, find.highlightStamps[key] == stamp { continue }
        let surfaces = selectionSurfaces(in: host)
        let highlights = find.engine.highlights(forRow: key, surfaceTexts: surfaces.map(\.string))
        for (surface, highlight) in zip(surfaces, highlights) {
          surface.transcriptFindHighlights = highlight
        }
      }
    }
    for key in find.highlightStamps.keys where stamps[key] == nil {
      if let host = mountedHosts[key] { clearFindHighlights(in: host) }
    }
    find.highlightStamps = stamps
  }

  /// Recycled hosts must never carry a highlight into their next row.
  func findHostWillDetach(_ host: TranscriptMountedRowHost, key: String) {
    guard find.highlightStamps.removeValue(forKey: key) != nil else { return }
    clearFindHighlights(in: host)
  }

  private func clearFindHighlights(in host: NSView) {
    for surface in selectionSurfaces(in: host) {
      surface.transcriptFindHighlights = nil
    }
  }

  // MARK: Navigation

  /// Scrolls the current match into the unobstructed part of the viewport.
  /// An unmounted row is first brought on screen at its estimated position;
  /// once it mounts, the match itself is centered. A freshly mounted row
  /// can settle a frame later, so the centering pass repeats briefly.
  func revealCurrentFindMatch() {
    find.revealGeneration &+= 1
    let generation = find.revealGeneration
    guard initialPresentationGate.isReady,
      let match = find.engine.results.current,
      let index = virtualLayout.indexByKey[match.rowKey]
    else { return }

    if findMatchSurfaceRect(match) == nil {
      let region = unobstructedFindRegion()
      let rowTop = rowFrame(at: index).minY
      scrollForFind(toTop: rowTop - (region.minY - contentView.bounds.minY) - region.height * 0.3)
      transcriptDocumentView.layoutSubtreeIfNeeded()
      applyFindHighlights()
    }
    centerFindMatchIfNeeded(match)

    for delay in [0.0, 0.12, 0.3] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self, find.revealGeneration == generation,
          find.engine.results.current == match
        else { return }
        applyFindHighlights()
        centerFindMatchIfNeeded(match)
      }
    }
  }

  private func centerFindMatchIfNeeded(_ match: TranscriptFindMatch) {
    guard let (surface, rect) = findMatchSurfaceRect(match) else { return }
    revealHorizontally(rect, in: surface)
    let documentRect = transcriptDocumentView.convert(rect, from: surface)
    let region = unobstructedFindRegion()
    guard documentRect.minY < region.minY || documentRect.maxY > region.maxY else { return }
    let offsetInRegion = region.height * 0.4 - documentRect.height / 2
    scrollForFind(
      toTop: documentRect.minY - offsetInRegion - (region.minY - contentView.bounds.minY)
    )
  }

  /// The current match's surface and bounds in that surface, when its row is
  /// mounted and laid out.
  private func findMatchSurfaceRect(
    _ match: TranscriptFindMatch
  ) -> (TranscriptSurfaceTextView, NSRect)? {
    guard let host = mountedHosts[match.rowKey] else { return nil }
    for surface in selectionSurfaces(in: host) {
      guard let range = surface.transcriptFindHighlights?.currentRange else { continue }
      let rects = surface.transcriptTextRects(for: range)
      guard let first = rects.first else { return nil }
      return (surface, rects.dropFirst().reduce(first) { $0.union($1) })
    }
    return nil
  }

  /// The viewport in document coordinates, less the find bar above and the
  /// floating composer below.
  private func unobstructedFindRegion() -> CGRect {
    let visible = contentView.bounds
    let composer = rowByKey[TranscriptVirtualRow.ID.bottomSpacer.layoutKey]?.estimatedHeight ?? 0
    let top = visible.minY + Self.findBarClearance
    let bottom = max(top + 1, visible.maxY - composer)
    return CGRect(x: visible.minX, y: top, width: visible.width, height: bottom - top)
  }

  /// Code blocks and tables scroll sideways inside the row; bring a match
  /// past their right edge into view without touching the transcript.
  private func revealHorizontally(_ rect: NSRect, in surface: NSView) {
    var ancestor = surface.superview
    while let view = ancestor, view !== self {
      if let scrollView = view as? NSScrollView {
        let clip = scrollView.contentView
        let target = clip.convert(rect, from: surface)
        var origin = clip.bounds.origin
        let documentWidth = scrollView.documentView?.frame.width ?? clip.bounds.width
        if target.minX < origin.x + 8 || target.maxX > origin.x + clip.bounds.width - 8 {
          origin.x = min(
            max(0, target.midX - clip.bounds.width / 2),
            max(0, documentWidth - clip.bounds.width)
          )
          clip.scroll(to: origin)
          scrollView.reflectScrolledClipView(clip)
        }
        return
      }
      ancestor = view.superview
    }
  }

  /// A find jump moves the viewport the way a keyboard scroll does: it is
  /// user movement, so it drops restore locks and stops following the
  /// newest message.
  private func scrollForFind(toTop requestedTop: CGFloat) {
    let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
    let top = min(max(0, requestedTop), maximum)
    guard abs(top - contentView.bounds.minY) > 0.5 else { return }
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
    contentView.scroll(to: CGPoint(x: 0, y: top))
    reflectScrolledClipView(contentView)
    if viewportSnapshotGeneration == snapshotGeneration {
      viewportDidScroll()
    }
    updateMountedRows()
    emitViewportSnapshot()
  }
}
