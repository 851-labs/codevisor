import Foundation

struct SceneLissajousPath {
  private static let frequencies = (x: 3.0, y: 2.0)
  private static let samples = 3600
  private static let marginPoints = 24.0

  private let center: (x: Double, y: Double)
  private let amplitude: (x: Double, y: Double)
  private let radiansPerTick: Double

  init(canvasPoints: (width: Int, height: Int), windowPoints: (width: Int, height: Int), pointsPerSecond: Double) {
    center = (
      Double(canvasPoints.width - windowPoints.width) / 2, Double(canvasPoints.height - windowPoints.height) / 2
    )
    amplitude = (max(0, center.x - Self.marginPoints), max(0, center.y - Self.marginPoints))
    let speedPerRadian = Self.meanSpeedPerRadian(amplitude)
    let radiansPerSecond = speedPerRadian > 0 ? pointsPerSecond / speedPerRadian : 0
    radiansPerTick = radiansPerSecond / Double(BenchSceneTiming.ticksPerSecond)
  }

  func origin(atTick tick: Int) -> (x: Double, y: Double) {
    let angle = Double(tick) * radiansPerTick
    return (
      center.x + amplitude.x * sin(Self.frequencies.x * angle + .pi / 2),
      center.y + amplitude.y * sin(Self.frequencies.y * angle)
    )
  }

  private static func meanSpeedPerRadian(_ amplitude: (x: Double, y: Double)) -> Double {
    let total = (0..<samples).reduce(0.0) { sum, sample in
      let angle = Double(sample) / Double(samples) * 2 * .pi
      let dx = amplitude.x * frequencies.x * cos(frequencies.x * angle + .pi / 2)
      let dy = amplitude.y * frequencies.y * cos(frequencies.y * angle)
      return sum + (dx * dx + dy * dy).squareRoot()
    }
    return total / Double(samples)
  }
}
