import ScreenSharingBench
import Testing

struct BenchCIEDE2000Tests {
  struct Pair: Sendable, CustomTestStringConvertible {
    let first: (Double, Double, Double)
    let second: (Double, Double, Double)
    let expected: Double

    var testDescription: String { "\(first) vs \(second)" }
  }

  static let sharmaPairs = [
    Pair(first: (50, 2.6772, -79.7751), second: (50, 0, -82.7485), expected: 2.0425),
    Pair(first: (50, 0, 0), second: (50, -1, 2), expected: 2.3669),
    Pair(first: (50, 2.5, 0), second: (73, 25, -18), expected: 27.1492),
    Pair(first: (60.2574, -34.0099, 36.2677), second: (60.4626, -34.1751, 39.4387), expected: 1.2644),
    Pair(first: (22.7233, 20.0904, -46.6940), second: (23.0331, 14.9730, -42.5619), expected: 2.0373),
    Pair(first: (2.0776, 0.0795, -1.1350), second: (0.9033, -0.0636, -0.5514), expected: 0.9082),
  ]

  @Test(arguments: sharmaPairs) func matchesSharmasTestData(_ pair: Pair) {
    let first = BenchLab(lightness: pair.first.0, a: pair.first.1, b: pair.first.2)
    let second = BenchLab(lightness: pair.second.0, a: pair.second.1, b: pair.second.2)

    #expect(abs(BenchCIEDE2000.difference(first, second) - pair.expected) < 0.0001)
    #expect(abs(BenchCIEDE2000.difference(second, first) - pair.expected) < 0.0001)
  }

  @Test func sRGBWhiteIsLightness100AndNeutral() {
    let white = BenchLab(BenchRGB(red: 255, green: 255, blue: 255))

    #expect(abs(white.lightness - 100) < 0.01 && abs(white.a) < 0.01 && abs(white.b) < 0.01)
  }
}
