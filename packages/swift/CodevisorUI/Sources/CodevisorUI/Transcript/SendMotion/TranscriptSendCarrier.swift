#if canImport(UIKit)
  import QuartzCore
  import UIKit

  @MainActor
  final class TranscriptSendCarrier {
    let view: UIView

    private struct Level {
      weak var source: CALayer?
      let mirror: UIView
      var copied: [String: CFTimeInterval] = [:]
    }

    private let root: UIView
    private var levels: [Level]
    private(set) weak var content: UIView?

    private static let geometryKeyPaths = ["position", "bounds", "transform", "sublayerTransform", "anchorPoint"]

    init?(content: UIView, overlay: TranscriptSendOverlayView) {
      guard let window = content.window, overlay.window === window else { return nil }
      var chain: [UIView] = []
      var current: UIView? = content
      while let view = current, view !== window {
        chain.append(view)
        current = view.superview
      }
      guard current === window else { return nil }

      var parent: UIView = overlay
      var levels: [Level] = []
      for source in chain.reversed() {
        let mirror = UIView()
        mirror.isUserInteractionEnabled = false
        mirror.clipsToBounds = false
        mirror.backgroundColor = .clear
        parent.addSubview(mirror)
        levels.append(Level(source: source.layer, mirror: mirror))
        parent = mirror
      }
      self.levels = levels
      self.content = content
      root = levels[0].mirror
      view = UIView()
      view.isUserInteractionEnabled = false
      view.clipsToBounds = false
      parent.addSubview(view)
      sync()
    }

    func sync() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      UIView.performWithoutAnimation {
        for index in levels.indices {
          guard let source = levels[index].source else { continue }
          let mirror = levels[index].mirror.layer
          mirror.anchorPoint = source.anchorPoint
          mirror.bounds = source.bounds
          mirror.position = source.position
          mirror.transform = source.transform
          mirror.sublayerTransform = source.sublayerTransform
          for key in source.animationKeys() ?? [] {
            guard let animation = source.animation(forKey: key) as? CAPropertyAnimation,
              let keyPath = animation.keyPath,
              Self.geometryKeyPaths.contains(where: { keyPath.hasPrefix($0) }),
              levels[index].copied[key] != animation.beginTime || mirror.animation(forKey: key) == nil,
              let copy = animation.copy() as? CAPropertyAnimation
            else { continue }
            copy.delegate = nil
            mirror.add(copy, forKey: key)
            levels[index].copied[key] = animation.beginTime
          }
        }
        if let content = levels.last?.mirror {
          view.frame = CGRect(origin: .zero, size: content.bounds.size)
        }
      }
      CATransaction.commit()
    }

    func rect(displayedAt screenRect: CGRect, in overlay: UIView) -> CGRect {
      guard let content else { return screenRect }
      guard let contentLayer = content.layer.presentation(),
        let overlayLayer = overlay.layer.presentation()
      else { return content.convert(screenRect, from: overlay) }
      return contentLayer.convert(screenRect, from: overlayLayer)
    }

    func remove() {
      root.removeFromSuperview()
    }
  }
#endif
