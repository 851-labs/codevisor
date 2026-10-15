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

    var hostWindow: UIWindow? { window }

    func releaseIfIdle() {}
  #else
    init() {
      super.init(frame: .zero)
      autoresizingMask = [.width, .height]
      wantsLayer = true
    }

    override public var isFlipped: Bool { true }
    override public func hitTest(_: NSPoint) -> NSView? { nil }

    private(set) weak var hostWindow: NSWindow?

    static func overlay(in window: NSWindow) -> TranscriptSendOverlayView? {
      let overlayWindow =
        (window.childWindows ?? []).lazy.compactMap { $0 as? TranscriptSendOverlayWindow }.first
        ?? TranscriptSendOverlayWindow()
      overlayWindow.level = window.level
      overlayWindow.setFrame(window.frame, display: false)
      if overlayWindow.parent !== window {
        window.addChildWindow(overlayWindow, ordered: .above)
      }
      let overlay = overlayWindow.overlay
      overlay.hostWindow = window
      overlay.frame = overlayWindow.contentView?.bounds ?? .zero
      return overlay
    }

    func releaseIfIdle() {
      guard subviews.isEmpty, let overlayWindow = window, let parent = overlayWindow.parent else { return }
      parent.removeChildWindow(overlayWindow)
      overlayWindow.orderOut(nil)
    }
  #endif

  @available(*, unavailable)
  required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

  func point(inHostWindow point: CGPoint) -> CGPoint {
    #if canImport(UIKit)
      return convert(point, from: nil)
    #else
      guard let content = hostWindow?.contentView else { return point }
      let local = content.isFlipped ? point : CGPoint(x: point.x, y: content.bounds.height - point.y)
      return rect(of: content, CGRect(origin: local, size: .zero)).origin
    #endif
  }

  func rect(of view: TranscriptSendPlatformView, _ rect: CGRect) -> CGRect {
    #if canImport(UIKit)
      return convert(rect, from: view)
    #else
      guard let viewWindow = view.window, let ownWindow = window, viewWindow !== ownWindow else {
        return convert(rect, from: view)
      }
      let onScreen = viewWindow.convertToScreen(view.convert(rect, to: nil))
      return convert(ownWindow.convertFromScreen(onScreen), from: nil)
    #endif
  }
}

#if canImport(AppKit) && !canImport(UIKit)
  final class TranscriptSendOverlayWindow: NSWindow {
    let overlay = TranscriptSendOverlayView()

    init() {
      super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
      isOpaque = false
      backgroundColor = .clear
      hasShadow = false
      ignoresMouseEvents = true
      isReleasedWhenClosed = false
      collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
      let content = NSView()
      content.wantsLayer = true
      contentView = content
      overlay.frame = content.bounds
      content.addSubview(overlay)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
  }
#endif
