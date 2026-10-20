import AppKit
import CodevisorUI
import QuartzCore

extension VirtualizedTranscriptScrollView {
  func applyBottomFade(_ fade: TranscriptBottomFade) {
    guard bottomFade != fade else { return }
    bottomFade = fade
    layoutBottomFadeMask()
  }

  func layoutBottomFadeMask() {
    guard let layer = contentView.layer else { return }
    let height = layer.bounds.height
    guard bottomFade != .none, height > 0 else {
      if layer.mask === bottomFadeMask { layer.mask = nil }
      bottomFadeMaskGeometry = nil
      return
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bottomFadeMask.frame = layer.bounds
    let flipped = layer.contentsAreFlipped()
    if bottomFadeMaskGeometry.map({ $0.height != height || $0.fade != bottomFade || $0.flipped != flipped }) ?? true {
      bottomFadeMaskGeometry = (height, bottomFade, flipped)
      let clearStart = max(0, 1 - bottomFade.clearHeight / height)
      let fadeStart = max(0, clearStart - bottomFade.fadeHeight / height)
      let steps = 8
      let stops = (0...steps).map { step -> (alpha: CGFloat, location: CGFloat) in
        let progress = CGFloat(step) / CGFloat(steps)
        let eased = progress * progress * (3 - 2 * progress)
        return (1 - eased, fadeStart + (clearStart - fadeStart) * progress)
      }
      bottomFadeMask.colors = ([(1, 0)] + stops + [(0, 1)]).map { NSColor.black.withAlphaComponent($0.alpha).cgColor }
      bottomFadeMask.locations = ([(1, 0)] + stops + [(0, 1)]).map { NSNumber(value: Double($0.location)) }
      bottomFadeMask.startPoint = CGPoint(x: 0.5, y: flipped ? 0 : 1)
      bottomFadeMask.endPoint = CGPoint(x: 0.5, y: flipped ? 1 : 0)
    }
    if layer.mask !== bottomFadeMask { layer.mask = bottomFadeMask }
    CATransaction.commit()
  }
}
