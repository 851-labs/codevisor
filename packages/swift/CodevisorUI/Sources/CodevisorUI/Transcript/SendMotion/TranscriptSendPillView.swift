import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

final class TranscriptSendPillView: TranscriptSendPlatformView {
  let backgroundLayer = CALayer()
  let shapeMask = CALayer()

  var shapeLayers: [CALayer] { [backgroundLayer, shapeMask] }

  var fill: CGColor? {
    didSet { backgroundLayer.backgroundColor = fill }
  }

  var hidesFill = false {
    didSet { backgroundLayer.opacity = hidesFill ? 0 : 1 }
  }

  func revealFill() {
    guard hidesFill else { return }
    hidesFill = false
    backgroundLayer.add(
      TranscriptSendLayerAnimations.fade(from: 0, to: 1, duration: TranscriptSendMotion.crossfadeDuration),
      forKey: "codevisor.send-fill")
  }

  init(frame: CGRect, cornerRadius: CGFloat) {
    super.init(frame: frame)
    #if canImport(UIKit)
      isUserInteractionEnabled = false
      clipsToBounds = false
    #else
      wantsLayer = true
    #endif
    for layer in shapeLayers {
      layer.cornerRadius = cornerRadius
      layer.cornerCurve = .continuous
      layer.frame = bounds
    }
    shapeMask.backgroundColor = CGColor(gray: 0, alpha: 1)
    transcriptSendLayer?.insertSublayer(backgroundLayer, at: 0)
    transcriptSendLayer?.mask = shapeMask
  }

  var backgroundYAxisPointsDown: Bool {
    #if canImport(UIKit)
      true
    #else
      guard let probe = subviews.first, let layer = probe.layer, bounds.height > 0,
        abs(probe.frame.minY - (bounds.height - probe.frame.maxY)) > 0.5
      else { return true }
      return abs(layer.frame.minY - probe.frame.minY) < 0.5
    #endif
  }

  func setTranscriptSendFrame(_ frame: CGRect) {
    #if canImport(UIKit)
      UIView.performWithoutAnimation { self.frame = frame }
    #else
      self.frame = frame
    #endif
  }

  #if !canImport(UIKit)
    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }
  #endif

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }
}
