import CoreGraphics
import Foundation

struct BotRowDrag: Equatable {
  enum Target: Equatable {
    case section(UUID)
    case insertion(Int)
  }

  let botID: UUID
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  var target: Target?

  var ghostFrame: CGRect { liftedFrame.offsetBy(dx: 0, dy: translation) }
  var ghostCenter: CGPoint { CGPoint(x: ghostFrame.midX, y: ghostFrame.midY) }
}
