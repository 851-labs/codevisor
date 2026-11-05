enum VCPLevelsExpectation {
  case rgb
  case fullRange
  case videoRange
  case fullRangeRoundTrip

  func values(_ colour: VCPLevelsRamp.Colour) -> [Int] {
    switch self {
    case .rgb: [Int(colour.red), Int(colour.green), Int(colour.blue)]
    case .fullRange: Self.ycbcr(colour, fullRange: true)
    case .videoRange: Self.ycbcr(colour, fullRange: false)
    case .fullRangeRoundTrip: Self.rgb(fromFullRange: Self.ycbcr(colour, fullRange: true))
    }
  }

  private static func ycbcr(_ colour: VCPLevelsRamp.Colour, fullRange: Bool) -> [Int] {
    let converted = EncodeLabReferencePicture.ycbcr(
      red: colour.red, green: colour.green, blue: colour.blue, fullRange: fullRange)
    return [converted.y, converted.cb, converted.cr]
  }

  private static func rgb(fromFullRange values: [Int]) -> [Int] {
    let (y, cb, cr) = (Double(values[0]), Double(values[1] - 128), Double(values[2] - 128))
    return [y + 1.5748 * cr, y - 0.187324 * cb - 0.468124 * cr, y + 1.8556 * cb].map {
      Int(min(255, max(0, $0.rounded())))
    }
  }
}
