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

  func rowFrame(at index: Int) -> CGRect {
    let viewportWidth = max(1, contentView.bounds.width)
    let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
    let rowWidth = min(Self.maxRowWidth, availableWidth)
    let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
    return CGRect(
      x: rowX,
      y: paginationHeaderLayout.rowOrigin(
        topPadding: Self.topPadding,
        rowOffset: virtualLayout.frame(at: index).minY
      ),
      width: rowWidth,
      height: virtualLayout.frame(at: index).height
    )
  }

  func position(host: TranscriptMountedRowHost, frame: CGRect) {
    // Height commits move every later row but do not change those rows'
    // content geometry. Assigning the complete frame for a y-only move
    // needlessly invalidates AppKit/SwiftUI layout; update size and origin
    // independently so already-laid-out hosts remain clean.
    if host.frame.size != frame.size {
      host.setFrameSize(frame.size)
    }
    if host.frame.origin != frame.origin {
      host.setFrameOrigin(frame.origin)
    }
  }
}
