import Foundation

struct BenchCIEDE2000Chroma {
  let first: Double
  let second: Double
  let mean: Double
  let meanHue: Double
  let hueDifference: Double
  let hueWeighting: Double

  init(_ one: BenchLab, _ two: BenchLab) {
    let g = BenchCIEDE2000.gFactor(meanChroma: (hypot(one.a, one.b) + hypot(two.a, two.b)) / 2)
    let primeA = (one.a * (1 + g), two.a * (1 + g))
    first = hypot(primeA.0, one.b)
    second = hypot(primeA.1, two.b)
    mean = (first + second) / 2
    let hues = (Self.hue(b: one.b, a: primeA.0), Self.hue(b: two.b, a: primeA.1))
    let bothChromatic = first * second != 0
    let deltaHue = bothChromatic ? Self.wrappedDifference(hues.0, hues.1) : 0
    hueDifference = 2 * sqrt(first * second) * sin(BenchCIEDE2000.radians(deltaHue / 2))
    meanHue = bothChromatic ? Self.meanHue(hues.0, hues.1) : hues.0 + hues.1
    hueWeighting = Self.weighting(meanHue)
  }

  private static func hue(b: Double, a: Double) -> Double {
    guard a != 0 || b != 0 else { return 0 }

    let degrees = atan2(b, a) * 180 / .pi
    return degrees < 0 ? degrees + 360 : degrees
  }

  private static func wrappedDifference(_ first: Double, _ second: Double) -> Double {
    let difference = second - first
    if difference > 180 { return difference - 360 }
    if difference < -180 { return difference + 360 }
    return difference
  }

  private static func meanHue(_ first: Double, _ second: Double) -> Double {
    let sum = first + second
    guard abs(first - second) > 180 else { return sum / 2 }

    return sum < 360 ? (sum + 360) / 2 : (sum - 360) / 2
  }

  private static func weighting(_ hue: Double) -> Double {
    1 - 0.17 * cos(BenchCIEDE2000.radians(hue - 30)) + 0.24 * cos(BenchCIEDE2000.radians(2 * hue))
      + 0.32 * cos(BenchCIEDE2000.radians(3 * hue + 6)) - 0.20 * cos(BenchCIEDE2000.radians(4 * hue - 63))
  }
}
