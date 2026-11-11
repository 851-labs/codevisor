import AppKit
import CodevisorUI
import TranscriptKit

extension VirtualizedTranscriptScrollView {
  private static let anchorSearchLimit = 64

  func resizeDocumentView(absorbingChangeFrom previousLayout: VirtualTranscriptLayout, previousDistance: CGFloat?) {
    defer { resizeDocumentView() }
    guard isPinnedForSlack(previousDistance: previousDistance) else {
      if !followsLatest { bottomSlack.reset() }
      return
    }
    guard let shift = anchorShift(from: previousLayout) else { return }

    let change = virtualLayout.totalHeight - previousLayout.totalHeight
    bottomSlack.absorb(rowsHeightChange: change - shift, at: CACurrentMediaTime())
    if bottomSlack.isActive { requestDisplayFrame() }
  }

  func decayBottomSlack(at time: TimeInterval) {
    guard bottomSlack.isActive else { return }
    guard followsLatest else {
      bottomSlack.reset()
      resizeDocumentView()
      return
    }

    requestDisplayFrame()
    guard bottomSlack.decay(at: time) else { return }

    applyPositionTransaction {
      resizeDocumentView()
      setDistanceFromBottom(0)
    }
    lastDistanceFromBottom = currentDistanceFromBottom()
  }

  private func isPinnedForSlack(previousDistance: CGFloat?) -> Bool {
    guard let previousDistance, followsLatest, initialPositionApplied, !inLiveResize else { return false }

    return previousDistance <= Self.atBottomThreshold && disclosureViewportAnchor == nil
      && lockedRestoreDistance == nil && disclosureCollapsePresentations.isEmpty
  }

  private func anchorShift(from previousLayout: VirtualTranscriptLayout) -> CGFloat? {
    let rowsTop = paginationHeaderLayout.rowOrigin(topPadding: transcriptTopPadding, rowOffset: 0)
    let viewportTop = contentView.bounds.minY - rowsTop
    guard let first = previousLayout.index(nearestToOffset: viewportTop) else { return nil }

    let last = min(previousLayout.keys.count, first + Self.anchorSearchLimit)
    for index in first..<last {
      let previous = previousLayout.frame(at: index)
      guard previous.maxY > viewportTop else { continue }
      guard let newIndex = virtualLayout.indexByKey[previousLayout.keys[index]] else { continue }

      return virtualLayout.frame(at: newIndex).minY - previous.minY
    }
    return nil
  }
}
