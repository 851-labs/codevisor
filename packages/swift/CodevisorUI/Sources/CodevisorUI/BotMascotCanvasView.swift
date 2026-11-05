import Metal
import QuartzCore
@preconcurrency import RiveRuntime

#if os(macOS)
  import AppKit

  typealias BotMascotPlatformView = NSView
#else
  import UIKit

  typealias BotMascotPlatformView = UIView
#endif

final class BotMascotCanvasView: BotMascotPlatformView {
  var onWindowChange: (() -> Void)?

  #if os(macOS)
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
      Self.makeMetalLayer()
    }

    override func layout() {
      super.layout()
      resizeDrawable()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      resizeDrawable()
      onWindowChange?()
    }

    override func setFrameSize(_ size: NSSize) {
      super.setFrameSize(size)
      resizeDrawable()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      resizeDrawable()
    }

    private var scale: CGFloat {
      window?.backingScaleFactor ?? 2
    }
  #else
    override class var layerClass: AnyClass {
      CAMetalLayer.self
    }

    override init(frame: CGRect) {
      super.init(frame: frame)
      Self.configure(layer as? CAMetalLayer)
      backgroundColor = .clear
      isOpaque = false
      isUserInteractionEnabled = false
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      resizeDrawable()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      resizeDrawable()
      onWindowChange?()
    }

    private var scale: CGFloat {
      window?.screen.scale ?? traitCollection.displayScale
    }
  #endif

  required init?(coder: NSCoder) {
    nil
  }

  var drawableSide: Int? {
    guard window != nil, let size = metalLayer?.drawableSize, size.width > 0, size.height > 0 else { return nil }

    return Int(size.width)
  }

  func nextDrawable() -> (any CAMetalDrawable)? {
    guard drawableSide != nil else { return nil }

    return metalLayer?.nextDrawable()
  }

  private var metalLayer: CAMetalLayer? {
    layer as? CAMetalLayer
  }

  private func resizeDrawable() {
    guard let metalLayer else { return }

    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }

  private static func makeMetalLayer() -> CAMetalLayer {
    let layer = CAMetalLayer()
    configure(layer)
    return layer
  }

  private static func configure(_ layer: CAMetalLayer?) {
    guard let layer else { return }

    layer.device = BotMascotPainter.device
    layer.pixelFormat = MTLRiveColorPixelFormat()
    layer.framebufferOnly = false
    layer.isOpaque = false
    layer.backgroundColor = CGColor(gray: 0, alpha: 0)
  }
}
