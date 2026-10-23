import Observation
import SwiftUI

@MainActor
@Observable
final class FirstLaunchLanding {
  private(set) var composerFrame: CGRect?

  func reportComposer(_ frame: CGRect) {
    guard composerFrame != frame else { return }
    composerFrame = frame
  }
}
