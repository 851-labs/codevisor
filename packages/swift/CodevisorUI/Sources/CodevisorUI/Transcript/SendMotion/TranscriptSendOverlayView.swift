import QuartzCore
import SwiftUI

#if canImport(UIKit)
  import UIKit
#else
  import AppKit
#endif

public final class TranscriptSendOverlayView: TranscriptSendPlatformView {
  #if canImport(UIKit)
    init(window: UIWindow) {
      super.init(frame: window.bounds)
      autoresizingMask = [.flexibleWidth, .flexibleHeight]
      isUserInteractionEnabled = false
      accessibilityElementsHidden = true
      backgroundColor = .clear
    }

    static func overlay(in window: UIWindow) -> TranscriptSendOverlayView? {
      let overlay =
        window.subviews.lazy.compactMap { $0 as? TranscriptSendOverlayView }.first
        ?? TranscriptSendOverlayView(window: window)
      if overlay.superview !== window { window.addSubview(overlay) }
      window.bringSubviewToFront(overlay)
      return overlay
    }

    func releaseIfIdle() {}
  #else
    init() {
      super.init(frame: .zero)
      autoresizingMask = [.width, .height]
      wantsLayer = true
      setAccessibilityHidden(true)
    }

    override public var isFlipped: Bool { true }
    override public func hitTest(_: NSPoint) -> NSView? { nil }

    static func overlay(in window: NSWindow) -> TranscriptSendOverlayView? {
      guard let root = window.contentView?.superview else { return nil }
      let overlay =
        root.subviews.lazy.compactMap { $0 as? TranscriptSendOverlayView }.first
        ?? TranscriptSendOverlayView()
      if overlay.superview !== root {
        root.addSubview(overlay, positioned: .above, relativeTo: nil)
      }
      overlay.frame = root.bounds
      return overlay
    }

    func releaseIfIdle() {
      guard subviews.isEmpty else { return }
      removeFromSuperview()
    }
  #endif

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  func makeTrack() -> TranscriptSendTrack {
    let track = TranscriptSendTrack(frame: bounds)
    addSubview(track)
    return track
  }

  func point(inHostWindow point: CGPoint) -> CGPoint {
    #if canImport(UIKit)
      return convert(point, from: nil)
    #else
      guard let content = window?.contentView else { return point }
      let local = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
      return convert(local, from: content)
    #endif
  }
}
