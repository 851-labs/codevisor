import CoreGraphics

import TranscriptKit

extension VirtualTranscriptLayout {
  var heights: [CGFloat] { keys.indices.map { frame(at: $0).height } }
  var topOffsets: [CGFloat] { keys.indices.map { frame(at: $0).minY } }

  func distanceFromBottom(viewportTop: CGFloat, viewportHeight: CGFloat) -> CGFloat {
    max(0, totalHeight - (max(0, viewportTop) + max(0, viewportHeight)))
  }
}
