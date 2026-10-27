import AppKit
import CodevisorUI
import StreamMarkdown
import TranscriptKit

@MainActor
final class TranscriptFindState {
  struct HighlightStamp: Equatable {
    let query: String
    let currentOrdinal: Int?
    let host: ObjectIdentifier
    let content: TranscriptVirtualRow.Content
  }

  let engine = TranscriptFindEngine()
  weak var model: TranscriptFindModel?
  var highlightStamps: [String: HighlightStamp] = [:]
  var revealGeneration = 0
}

extension VirtualizedTranscriptScrollView: TranscriptFindTarget {
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
    if find.engine.step(by: delta) {
      findResultsDidChange(reveal: true)
    }
  }

  func transcriptFindDidDismiss(_ model: TranscriptFindModel) {
    find.revealGeneration &+= 1
    find.engine.clear()
    findResultsDidChange(reveal: false)
    if let window, window.firstResponder !== self {
      window.makeFirstResponder(self)
    }
  }

  private func findResultsDidChange(reveal: Bool) {
    find.model?.publish(find.engine.results)
    applyFindHighlights()
    if reveal { revealCurrentFindMatch() }
  }

  func scheduleFindRefreshIfNeeded() {
    find.engine.refresh(rows: rows, theme: markdownRowStyle.markdown)
  }

  private func firstVisibleRowIndex() -> Int {
    guard
      let index = virtualLayout.index(
        nearestToOffset: unobstructedViewport.minY - transcriptRowsOrigin
      ),
      virtualLayout.keys.indices.contains(index)
    else { return 0 }
    let key = virtualLayout.keys[index]
    return rows.firstIndex { $0.layoutKey == key } ?? 0
  }

  func refreshFindHighlightsIfNeeded() {
    if find.engine.isActive || !find.highlightStamps.isEmpty {
      applyFindHighlights()
    }
  }

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
        if host is TranscriptMarkdownRowHost, find.highlightStamps[key] == stamp { continue }
        let surfaces = selectionSurfaces(in: host)
        let highlights = find.engine.highlights(forRow: key, surfaceTexts: surfaces.map(\.transcriptString))
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

  func findHostWillDetach(_ host: TranscriptMountedRowHost, key: String) {
    guard find.highlightStamps.removeValue(forKey: key) != nil else { return }
    clearFindHighlights(in: host)
  }

  private func clearFindHighlights(in host: NSView) {
    for surface in selectionSurfaces(in: host) {
      surface.transcriptFindHighlights = nil
    }
  }

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

  private func findMatchSurfaceRect(
    _ match: TranscriptFindMatch
  ) -> ((any TranscriptTextSurface), NSRect)? {
    guard let host = mountedHosts[match.rowKey] else { return nil }
    for surface in selectionSurfaces(in: host) {
      guard let range = surface.transcriptFindHighlights?.currentRange else { continue }
      let rects = surface.transcriptTextRects(for: range)
      guard let first = rects.first else { return nil }
      return (surface, rects.dropFirst().reduce(first) { $0.union($1) })
    }
    return nil
  }

  private func unobstructedFindRegion() -> CGRect {
    let visible = unobstructedViewport
    let top = visible.minY + Self.findBarClearance
    let bottom = max(top + 1, visible.maxY)
    return CGRect(x: visible.minX, y: top, width: visible.width, height: bottom - top)
  }

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
