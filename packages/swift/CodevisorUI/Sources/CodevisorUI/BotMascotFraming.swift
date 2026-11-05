import CoreGraphics

enum BotMascotFraming {
  static let artboardSide: CGFloat = 500
  static let figureBox = CGRect(x: 51, y: 30, width: 398, height: 398)

  static func artboardPoint(_ point: CGPoint, inFigureOfSide side: CGFloat) -> CGPoint {
    guard side > 0 else { return point }

    let unit = figureBox.width / side
    return CGPoint(x: figureBox.minX + point.x * unit, y: figureBox.minY + point.y * unit)
  }
}
