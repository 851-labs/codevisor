import Foundation

public enum BenchCIEDE2000 {
  private static let twentyFiveToTheSeventh = Double(6_103_515_625)

  public static func difference(_ first: BenchLab, _ second: BenchLab) -> Double {
    let chroma = BenchCIEDE2000Chroma(first, second)
    let lightnessTerm = (second.lightness - first.lightness) / lightnessWeight(first, second)
    let chromaTerm = (chroma.second - chroma.first) / (1 + 0.045 * chroma.mean)
    let hueTerm = chroma.hueDifference / (1 + 0.015 * chroma.mean * chroma.hueWeighting)
    let rotation = rotationTerm(meanHue: chroma.meanHue, meanChroma: chroma.mean)
    let total = lightnessTerm * lightnessTerm + chromaTerm * chromaTerm + hueTerm * hueTerm
    return sqrt(max(0, total + rotation * chromaTerm * hueTerm))
  }

  private static func lightnessWeight(_ first: BenchLab, _ second: BenchLab) -> Double {
    let offset = (first.lightness + second.lightness) / 2 - 50
    return 1 + 0.015 * offset * offset / sqrt(20 + offset * offset)
  }

  private static func rotationTerm(meanHue: Double, meanChroma: Double) -> Double {
    let angle = 30 * exp(-pow((meanHue - 275) / 25, 2))
    let seventh = pow(meanChroma, 7)
    return -2 * sqrt(seventh / (seventh + twentyFiveToTheSeventh)) * sin(radians(2 * angle))
  }

  static func radians(_ degrees: Double) -> Double {
    degrees * .pi / 180
  }

  static func gFactor(meanChroma: Double) -> Double {
    let seventh = pow(meanChroma, 7)
    return 0.5 * (1 - sqrt(seventh / (seventh + twentyFiveToTheSeventh)))
  }
}
