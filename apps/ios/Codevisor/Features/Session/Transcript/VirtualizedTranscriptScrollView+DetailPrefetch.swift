import CodevisorCore
import CodevisorUI
import TranscriptKit
import UIKit

extension VirtualizedTranscriptScrollView {
  func checkForDetailPrefetch(threshold: CGFloat) {
    for (index, row) in rows.enumerated() {
      guard case let .workedDetailPage(request) = row.content else { continue }
      let frame = virtualLayout.frame(at: index)
      let edge = transcriptRowsOrigin + (request.previous ? frame.maxY : frame.minY)
      let viewportEdge = request.previous ? contentOffset.y : (contentOffset.y + viewportHeight)
      if detailPrefetchPolicy.requestIfNeeded(
        request, distance: edge - viewportEdge, threshold: threshold,
        request: { [weak self] in self?.sessionController?.requestTranscriptDetailPage(request) == true })
      {
        return
      }
    }
  }
}
