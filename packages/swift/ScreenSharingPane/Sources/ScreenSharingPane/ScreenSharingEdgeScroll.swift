import CoreGraphics

enum ScreenSharingEdgeScroll {
  static let band: CGFloat = 56
  static let maximumSpeed: CGFloat = 14

  static func step(finger: CGPoint, in frame: CGRect) -> CGVector {
    func speed(_ distance: CGFloat) -> CGFloat {
      guard distance < band else { return 0 }
      return maximumSpeed * (1 - max(0, distance) / band)
    }
    let dx = speed(frame.maxX - finger.x) - speed(finger.x - frame.minX)
    let dy = speed(frame.maxY - finger.y) - speed(finger.y - frame.minY)
    return CGVector(dx: dx, dy: dy)
  }
}
