import CoreGraphics

import TranscriptKit

extension VirtualTranscriptLayout {
  var heights: [CGFloat] { keys.indices.map { frame(at: $0).height } }
  var topOffsets: [CGFloat] { keys.indices.map { frame(at: $0).minY } }
}
