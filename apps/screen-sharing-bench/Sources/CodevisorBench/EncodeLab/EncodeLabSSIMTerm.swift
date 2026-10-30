struct EncodeLabSSIMTerm {
  static let c1: Float = (0.01 * 255) * (0.01 * 255)
  static let c2: Float = (0.03 * 255) * (0.03 * 255)

  let meanX: Float
  let meanY: Float
  let squareX: Float
  let squareY: Float
  let productXY: Float

  var value: Float {
    let varianceX = squareX - meanX * meanX
    let varianceY = squareY - meanY * meanY
    let covariance = productXY - meanX * meanY
    let numerator = (2 * meanX * meanY + Self.c1) * (2 * covariance + Self.c2)
    let denominator = (meanX * meanX + meanY * meanY + Self.c1) * (varianceX + varianceY + Self.c2)
    return numerator / denominator
  }
}
