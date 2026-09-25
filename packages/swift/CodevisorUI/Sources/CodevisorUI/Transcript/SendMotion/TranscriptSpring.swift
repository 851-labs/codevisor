import Foundation

/// A unit-mass damped spring, described the way SwiftUI describes one
/// (response and damping fraction) and convertible to Core Animation's
/// physical parameters. Core Animation integrates the same equation on the
/// render server, so a spring built here keeps moving smoothly even while
/// the main thread is busy.
public struct TranscriptSpring: Equatable, Sendable {
  /// The undamped period, in seconds.
  public let response: Double
  /// 1 is critically damped (no overshoot); below 1 overshoots its target.
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

  /// Remaining displacement, as a fraction of the starting displacement,
  /// `time` seconds after release from rest. Negative values are overshoot.
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

  /// The time after which the motion stays within `tolerance` of its
  /// target, as a fraction of the starting displacement. Used as the Core
  /// Animation duration so the animation ends exactly when it has visibly
  /// settled rather than on Core Animation's more conservative estimate.
  public func settlingDuration(tolerance: Double = 0.002) -> TimeInterval {
    let omega = angularFrequency
    let zeta = dampingFraction
    if zeta < 1 {
      // The decaying envelope bounds every oscillation, including the
      // zero crossings a sampled search would mistake for rest.
      let amplitude = 1 / (1 - zeta * zeta).squareRoot()
      return log(amplitude / tolerance) / (zeta * omega)
    }
    // Critically and over-damped motion approaches monotonically.
    let step = 1.0 / 240
    var time = step
    while displacementFraction(at: time) > tolerance, time < 10 {
      time += step
    }
    return time
  }
}
