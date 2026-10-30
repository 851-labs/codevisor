import Accelerate

enum EncodeLabSimilarity {
  static let peak: Float = 255
  static let identicalPSNR = 100.0

  static func psnr(_ reference: [Float], _ decoded: [Float]) -> Double {
    psnr(meanSquaredError: meanSquaredError(reference, decoded))
  }

  static func psnr(_ reference: [[Float]], _ decoded: [[Float]]) -> Double {
    let errors = zip(reference, decoded).map { meanSquaredError($0, $1) }
    return psnr(meanSquaredError: errors.reduce(0, +) / Double(errors.count))
  }

  static func ssim(_ reference: [Float], _ decoded: [Float], width: Int, height: Int) throws -> Double {
    let blur = EncodeLabGaussianBlur(width: width, height: height)
    let means = (x: try blur.apply(reference), y: try blur.apply(decoded))
    let squares = (
      x: try blur.apply(vDSP.multiply(reference, reference)), y: try blur.apply(vDSP.multiply(decoded, decoded)),
      xy: try blur.apply(vDSP.multiply(reference, decoded))
    )
    var total = 0.0
    for index in 0..<reference.count {
      total += Double(
        EncodeLabSSIMTerm(
          meanX: means.x[index], meanY: means.y[index], squareX: squares.x[index], squareY: squares.y[index],
          productXY: squares.xy[index]
        ).value)
    }
    return total / Double(reference.count)
  }

  private static func meanSquaredError(_ reference: [Float], _ decoded: [Float]) -> Double {
    Double(vDSP.distanceSquared(reference, decoded)) / Double(reference.count)
  }

  private static func psnr(meanSquaredError: Double) -> Double {
    guard meanSquaredError > 0 else { return identicalPSNR }

    return min(identicalPSNR, 10 * log10(Double(peak * peak) / meanSquaredError))
  }
}
