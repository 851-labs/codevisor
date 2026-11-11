import AppKit
import CodevisorUI
import SwiftUI

@MainActor
final class TranscriptBubbleBackgroundView: NSView {
  private static let highlightOpacity: CGFloat = 0.14
  private static let highlightDuration: CFTimeInterval = 0.15
  private let highlight = CALayer()

  var cornerRadius: CGFloat = 0 {
    didSet {
      guard cornerRadius != oldValue else { return }
      layer?.cornerRadius = cornerRadius
    }
  }

  var isHighlighted = false {
    didSet {
      guard isHighlighted != oldValue else { return }
      animateHighlight()
    }
  }

  override var isFlipped: Bool { true }
  override var wantsUpdateLayer: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    highlight.backgroundColor = NSColor.black.cgColor
    highlight.opacity = 0
    layer?.addSublayer(highlight)
    setAccessibilityHidden(true)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_: NSPoint) -> NSView? { nil }

  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = NSColor(Color.bubbleBackground).cgColor
    }
  }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    highlight.frame = bounds
    CATransaction.commit()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    needsLayout = true
  }

  private func animateHighlight() {
    let target: Float = isHighlighted ? Float(Self.highlightOpacity) : 0
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = highlight.presentation()?.opacity ?? highlight.opacity
    animation.toValue = target
    animation.duration = Self.highlightDuration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
    highlight.opacity = target
    highlight.add(animation, forKey: "opacity")
  }
}
