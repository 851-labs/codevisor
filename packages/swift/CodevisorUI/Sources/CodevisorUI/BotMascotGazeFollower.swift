import CoreGraphics
import Foundation

struct BotMascotGaze: Equatable {
  let x: Float
  let y: Float
  let weight: Float

  static let none = BotMascotGaze(x: 0, y: 0, weight: 0)
}

struct BotMascotGazeFollower {
  static let origin = CGPoint(x: 250, y: 236.1)
  static let reach = CGSize(width: 170, height: 150)

  private static let followHz = 2.4
  private static let returnHz = 0.45
  private static let engageHz = 2.0
  private static let releaseHz = 0.35
  private static let stillAfter = 2.5
  private static let moved = 1.5
  private static let maxStep = 0.25
  private static let substep = 1.0 / 120
  private static let released = 0.003

  private var point: (x: Spring, y: Spring)?
  private var weight = Spring(x: 0)
  private var last: CGPoint?
  private var still = 0.0

  mutating func step(toward target: CGPoint?, seconds dt: Double) -> BotMascotGaze {
    let seconds = min(max(dt, 0), Self.maxStep)
    watch(target, seconds: seconds)
    let aim = still < Self.stillAfter ? target : nil
    guard var point = point ?? aim.map({ (Spring(x: $0.x), Spring(x: $0.y)) }) else { return .none }

    settle(&point, aim: aim, seconds: seconds)
    self.point = point
    if aim == nil, weight.x < Self.released { return release() }
    return gaze(at: CGPoint(x: point.x.x, y: point.y.x))
  }

  private mutating func watch(_ target: CGPoint?, seconds: Double) {
    let moved =
      target.map { target in last.map { hypot(target.x - $0.x, target.y - $0.y) > Self.moved } ?? true } ?? false
    still = moved ? 0 : still + seconds
    if moved || target == nil { last = target }
  }

  private mutating func settle(_ point: inout (x: Spring, y: Spring), aim: CGPoint?, seconds: Double) {
    let toward = aim ?? Self.origin
    let pointHz = aim == nil ? Self.returnHz : Self.followHz
    let weightHz = aim == nil ? Self.releaseHz : Self.engageHz
    var left = seconds
    while left > 1e-9 {
      let h = min(Self.substep, left)
      point.x.pull(toward: toward.x, hz: pointHz, step: h)
      point.y.pull(toward: toward.y, hz: pointHz, step: h)
      weight.pull(toward: aim == nil ? 0 : 1, hz: weightHz, step: h)
      left -= Self.substep
    }
  }

  private mutating func release() -> BotMascotGaze {
    point = nil
    weight = Spring(x: 0)
    return .none
  }

  private func gaze(at point: CGPoint) -> BotMascotGaze {
    BotMascotGaze(
      x: Float(tanh((point.x - Self.origin.x) / Self.reach.width)),
      y: Float(tanh((point.y - Self.origin.y) / Self.reach.height)),
      weight: Float(min(max(weight.x, 0), 1))
    )
  }
}

private struct Spring {
  var x: Double
  var v = 0.0

  mutating func pull(toward aim: Double, hz: Double, step h: Double) {
    let w = 2 * Double.pi * hz
    v += h * (w * w * (aim - x) - 2 * w * v)
    x += h * v
  }
}
