import Foundation

public struct TranscriptSpring: Equatable, Sendable {
  public let response: Double
  public let dampingFraction: Double

  public init(response: Double, dampingFraction: Double) {
    precondition(response > 0 && dampingFraction > 0)
    self.response = response
    self.dampingFraction = dampingFraction
  }

  public var mass: Double { 1 }

  var angularFrequency: Double { 2 * .pi / response }

  public var stiffness: Double { angularFrequency * angularFrequency }

  public var damping: Double { 2 * dampingFraction * angularFrequency }

  public func displacementFraction(at time: Double) -> Double {
    guard time > 0 else { return 1 }
    let omega = angularFrequency
    let zeta = dampingFraction
    if zeta < 1 {
      let dampedOmega = omega * (1 - zeta * zeta).squareRoot()
      return exp(-zeta * omega * time)
        * (cos(dampedOmega * time) + zeta * omega / dampedOmega * sin(dampedOmega * time))
    }
    if zeta == 1 {
      return (1 + omega * time) * exp(-omega * time)
    }
    let root = (zeta * zeta - 1).squareRoot()
    let fast = -omega * (zeta + root)
    let slow = -omega * (zeta - root)
    return (fast * exp(slow * time) - slow * exp(fast * time)) / (fast - slow)
  }

  public func settlingDuration(tolerance: Double = 0.002) -> TimeInterval {
    let omega = angularFrequency
    let zeta = dampingFraction
    if zeta < 1 {
      let amplitude = 1 / (1 - zeta * zeta).squareRoot()
      return log(amplitude / tolerance) / (zeta * omega)
    }
    let step = 1.0 / 240
    var time = step
    while displacementFraction(at: time) > tolerance, time < 10 {
      time += step
    }
    return time
  }
}
