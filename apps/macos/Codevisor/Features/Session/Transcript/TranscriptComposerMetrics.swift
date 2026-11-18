import Foundation
import Observation

@MainActor
@Observable
final class TranscriptComposerMetrics {
  private(set) var height: CGFloat = 96
  private(set) var cardHeight: CGFloat = 0

  func update(height: CGFloat) {
    guard self.height != height else { return }

    self.height = height
  }

  func update(cardHeight: CGFloat) {
    guard self.cardHeight != cardHeight else { return }

    self.cardHeight = cardHeight
  }
}
