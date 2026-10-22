import Observation
import SwiftUI

@MainActor
@Observable
final class FirstLaunchLanding {
  private(set) var frames: [FirstLaunchLandingTarget: CGRect] = [:]
  private(set) var hasCaughtCard = false

  func report(_ frame: CGRect, for target: FirstLaunchLandingTarget) {
    guard frames[target] != frame else { return }
    frames[target] = frame
  }

  func catchCard() {
    hasCaughtCard = true
  }

  func frame(for target: FirstLaunchLandingTarget) -> CGRect? {
    frames[target]
  }
}
