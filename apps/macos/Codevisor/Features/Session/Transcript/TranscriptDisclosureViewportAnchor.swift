import CoreGraphics
import Foundation

struct TranscriptDisclosureViewportAnchor {
  let id: UUID
  let viewportTop: CGFloat
  var row: (key: String, viewportOffset: CGFloat)?
}
