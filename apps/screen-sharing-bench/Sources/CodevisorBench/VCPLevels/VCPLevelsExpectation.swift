enum VCPLevelsExpectation {
  case rgb
  case fullRange
  case videoRange
  case fullRangeRoundTrip
  case videoRangeRoundTrip

  func values(_ colour: VCPLevelsRamp.Colour) -> [Int] {
    switch self {
    case .rgb: [Int(colour.red), Int(colour.green), Int(colour.blue)]
    case .fullRange: Self.ycbcr(colour, fullRange: true)
    case .videoRange: Self.ycbcr(colour, fullRange: false)
    case .fullRangeRoundTrip: Self.rgb(Self.ycbcr(colour, fullRange: true), fullRange: true)
    case .videoRangeRoundTrip: Self.rgb(Self.ycbcr(colour, fullRange: false), fullRange: false)
    }
  }

  private static func ycbcr(_ colour: VCPLevelsRamp.Colour, fullRange: Bool) -> [Int] {
    let converted = EncodeLabReferencePicture.ycbcr(
      red: colour.red, green: colour.green, blue: colour.blue, fullRange: fullRange)
    return [converted.y, converted.cb, converted.cr]
  }

  private static func rgb(_ values: [Int], fullRange: Bool) -> [Int] {
    let (lumaScale, chromaScale, black) = fullRange ? (1.0, 1.0, 0.0) : (255.0 / 219, 255.0 / 224, 16.0)
    let y = (Double(values[0]) - black) * lumaScale
    let (cb, cr) = (Double(values[1] - 128) * chromaScale, Double(values[2] - 128) * chromaScale)
    return [y + 1.5748 * cr, y - 0.187324 * cb - 0.468124 * cr, y + 1.8556 * cb].map {
      Int(min(255, max(0, $0.rounded())))
    }
  }
}
