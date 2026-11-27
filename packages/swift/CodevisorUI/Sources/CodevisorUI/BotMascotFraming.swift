import CoreGraphics

enum BotMascotFraming {
  static let artboardSide: CGFloat = 500
  static let figureBox = CGRect(x: 51, y: 30, width: 398, height: 398)
  static let portraitBox = CGRect(x: 49.745, y: 39.49, width: 400.51, height: 400.51)
  static let portraitWithHatBox = CGRect(x: 31.745, y: 1.49, width: 436.51, height: 436.51)

  static func box(for framing: BotMascotStill.Framing, wearingHat: Bool) -> CGRect {
    switch framing {
    case .figure: figureBox
    case .portrait: wearingHat ? portraitWithHatBox : portraitBox
    }
  }

  static func artboardPoint(_ point: CGPoint, inFigureOfSide side: CGFloat) -> CGPoint {
    guard side > 0 else { return point }

    let unit = figureBox.width / side
    return CGPoint(x: figureBox.minX + point.x * unit, y: figureBox.minY + point.y * unit)
  }
}
