import UIKit

enum TranscriptPixelGeometry {
  static func displayScale(for view: UIView) -> CGFloat {
    max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
  }

  static func ceil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    (value * scale).rounded(.up) / scale
  }

  static func differs(_ lhs: CGFloat, _ rhs: CGFloat, scale: CGFloat) -> Bool {
    abs(lhs - rhs) * scale > 0.5
  }
}
