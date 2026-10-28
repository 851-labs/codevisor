#if canImport(AppKit)
  import AppKit

  extension Autocomplete {
    @MainActor
    final class PopperShadowWindow: NSWindow {
      static let nativeMenuShadowOpacity: Float = 0.19
      static let nativeMenuShadowRadius: CGFloat = 18
      static let nativeMenuShadowDrop: CGFloat = 14
      static let nativeMenuRimWidth: CGFloat = 0.5
      static let nativeMenuRimOpacity: CGFloat = 0.3
      private static let margin = nativeMenuShadowRadius * 2.5 + nativeMenuShadowDrop

      private let shadowLayer = CALayer()
      private let cutout = CAShapeLayer()
      private let rim = CAShapeLayer()

      init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        setAccessibilityElement(false)
        contentView = shadowView()
      }

      func surround(_ surface: CGRect, cornerRadius: CGFloat) {
        setFrame(surface.insetBy(dx: -Self.margin, dy: -Self.margin), display: false)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let shape = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        let surfacePath = CGPath(
          roundedRect: shape, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(surfacePath)
        let rimOutset = Self.nativeMenuRimWidth / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = bounds
        shadowLayer.shadowPath = surfacePath
        cutout.path = outside
        rim.frame = bounds
        rim.path = CGPath(
          roundedRect: shape.insetBy(dx: -rimOutset, dy: -rimOutset), cornerWidth: cornerRadius + rimOutset,
          cornerHeight: cornerRadius + rimOutset, transform: nil)
        CATransaction.commit()
      }

      private func shadowView() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = Self.nativeMenuShadowOpacity
        shadowLayer.shadowRadius = Self.nativeMenuShadowRadius
        shadowLayer.shadowOffset = CGSize(width: 0, height: -Self.nativeMenuShadowDrop)
        cutout.fillRule = .evenOdd
        shadowLayer.mask = cutout
        rim.fillColor = nil
        rim.lineWidth = Self.nativeMenuRimWidth
        rim.strokeColor = NSColor(white: 0, alpha: Self.nativeMenuRimOpacity).cgColor
        view.layer?.addSublayer(shadowLayer)
        view.layer?.addSublayer(rim)
        return view
      }
    }
  }
#endif
