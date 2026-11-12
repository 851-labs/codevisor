import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  func positionMountedRows(startingAt firstChangedIndex: Int? = nil) {
    for (key, host) in mountedHosts {
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

  func recenterMountedRows() {
    resizeDocumentView()
    positionPaginationLoadingIndicator()
    positionMountedRows()
    mountedHosts.values.forEach { $0.viewportDidMoveHorizontally() }
  }

  func rowFrame(at index: Int) -> CGRect {
    let viewportWidth = max(1, contentView.bounds.width)
    let rowWidth = Self.rowWidth(forViewportWidth: viewportWidth)
    let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
    return CGRect(
      x: rowX,
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
