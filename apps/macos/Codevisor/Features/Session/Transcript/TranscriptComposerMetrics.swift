import Foundation
import Observation

@MainActor
@Observable
final class TranscriptComposerMetrics {
  private(set) var height: CGFloat = 96

  func update(height: CGFloat) {
    guard self.height != height else { return }

    self.height = height
  }
}
