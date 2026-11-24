import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func positionMountedRows(startingAt firstChangedIndex: Int? = nil) {
    let liveResizeKeys = liveResizeKeys()
    if let liveResizeKeys { refreshRowsChangingWidth(among: liveResizeKeys) }
    for (key, host) in mountedHosts where liveResizeKeys?.contains(key) ?? true {
      guard let index = virtualLayout.indexByKey[key] else { continue }
      if let firstChangedIndex, index < firstChangedIndex { continue }
      let frame = rowFrame(at: index)
      guard host.frame.size != frame.size || host.frame.origin != frame.origin else {
        continue
      }
      position(host: host, frame: frame)
    }
  }

  func position(host: TranscriptMountedRowHost, at index: Int) {
    position(host: host, frame: rowFrame(at: index))
  }

  static func rowWidth(forViewportWidth viewportWidth: CGFloat) -> CGFloat {
    let availableWidth = max(1, viewportWidth - horizontalPadding * 2)
    return min(maxRowWidth, availableWidth)
  }

  func liveResizeKeys() -> Set<String>? {
    guard inLiveResize else { return nil }

    let range = windowPlanner.liveResizeRange(
      layout: virtualLayout, distanceFromBottom: lastViewportDistanceFromBottom,
      viewportHeight: contentView.bounds.height)
    return Set(virtualLayout.keys(in: range))
  }

  func refreshRowsChangingWidth(among keys: Set<String>) {
    let rowWidth = Self.rowWidth(forViewportWidth: contentView.bounds.width)
    let changing = keys.filter { key in
      mountedHosts[key].map { abs($0.frame.width - rowWidth) > 0.5 } ?? false
    }
    refreshMountedHosts(previousRowsByKey: nil, limitedTo: changing)
  }

  var rowsNeedReflow: Bool {
    abs(effectiveRowWidth - laidOutRowWidth) > 0.5
  }

  @discardableResult
  func reflowRowsIfNeeded() -> Bool {
    guard rowsNeedReflow else { return false }

    laidOutRowWidth = effectiveRowWidth
    _ = activateMeasurementCacheIfNeeded()
    if !inLiveResize { refreshMountedRootViews() }
    rebuildDocumentGeometry()
    if inLiveResize { settleMountedRowHeights() }
    return true
  }

  func rowColumnDidMove() {
    mountedHosts.values.forEach { $0.viewportDidMoveHorizontally() }
  }

  func rowFrame(at index: Int) -> CGRect {
    let rowWidth = Self.rowWidth(forViewportWidth: max(1, contentView.bounds.width))
    return CGRect(
      x: 0,
      y: paginationHeaderLayout.rowOrigin(
        topPadding: transcriptTopPadding,
        rowOffset: virtualLayout.frame(at: index).minY
      ),
      width: rowWidth,
      height: virtualLayout.frame(at: index).height
    )
  }

  func resizeDocumentView() {
    let frame = CGRect(
      x: 0,
      y: 0,
      width: max(1, contentView.bounds.width),
      height: documentHeight(rowsHeight: virtualLayout.totalHeight)
    )
    guard transcriptDocumentView.frame != frame else { return }

    transcriptDocumentView.frame = frame
  }

  func documentHeight(rowsHeight: CGFloat) -> CGFloat {
    paginationHeaderLayout.documentHeight(topPadding: transcriptTopPadding, rowsHeight: rowsHeight)
  }

  func position(host: TranscriptMountedRowHost, frame: CGRect) {
    if host.frame.size != frame.size {
      host.setFrameSize(frame.size)
    }
    if host.frame.origin != frame.origin {
      host.setFrameOrigin(frame.origin)
    }
  }
}
