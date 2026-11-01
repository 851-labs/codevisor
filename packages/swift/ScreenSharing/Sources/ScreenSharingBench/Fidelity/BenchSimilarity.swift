import Accelerate
import Foundation

public enum BenchSimilarity {
  public static let peak: Double = 255

  public static func psnr(_ reference: [Float], _ shown: [Float]) -> Double {
    psnr(meanSquaredError: BenchSquaredError(reference, shown).mean)
  }

  public static func psnr(_ reference: [[Float]], _ shown: [[Float]]) -> Double {
    let total = zip(reference, shown).reduce(BenchSquaredError.none) { $0 + BenchSquaredError($1.0, $1.1) }
    return psnr(meanSquaredError: total.mean)
  }

  public static func psnr(meanSquaredError: Double) -> Double {
    guard meanSquaredError > 0 else { return .infinity }

    return 10 * log10(peak * peak / meanSquaredError)
  }

  public static func ssimMap(_ reference: [Float], _ shown: [Float], width: Int, height: Int) throws -> [Float] {
    let blur = BenchGaussianBlur(width: width, height: height)
    let means = (x: try blur.apply(reference), y: try blur.apply(shown))
    let squares = (
      x: try blur.apply(vDSP.multiply(reference, reference)), y: try blur.apply(vDSP.multiply(shown, shown)),
      xy: try blur.apply(vDSP.multiply(reference, shown))
    )
    return (0..<reference.count).map { index in
      BenchSSIMTerm(
        meanX: means.x[index], meanY: means.y[index], squareX: squares.x[index], squareY: squares.y[index],
        productXY: squares.xy[index]
      ).value
    }
  }

  public static func ssim(_ reference: [Float], _ shown: [Float], width: Int, height: Int) throws -> Double {
    let map = try ssimMap(reference, shown, width: width, height: height)
    return Double(vDSP.sum(map)) / Double(map.count)
  }
}
