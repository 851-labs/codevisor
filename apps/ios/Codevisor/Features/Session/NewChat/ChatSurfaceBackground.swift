import SwiftUI
import UIKit

/// A live system-color fill. During first send its color can animate with
/// the sheet's bounds instead of changing immediately when reparented.
struct ChatSurfaceBackground: UIViewRepresentable {
  var fadeHeight: CGFloat = 0

  func makeUIView(context _: Context) -> ChatSurfaceBackgroundView {
    ChatSurfaceBackgroundView(fadeHeight: fadeHeight)
  }

  func updateUIView(_ view: ChatSurfaceBackgroundView, context _: Context) {
    view.fadeHeight = fadeHeight
  }
}

final class ChatSurfaceBackgroundView: UIView {
  var fadeHeight: CGFloat {
    didSet { if oldValue != fadeHeight { setNeedsLayout() } }
  }
  private let fill = UIView()
  private let gradient = CAGradientLayer()
  private var isPromoting = false

  init(fadeHeight: CGFloat) {
    self.fadeHeight = fadeHeight
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    layer.addSublayer(gradient)
    addSubview(fill)
    registerForTraitChanges([
      UITraitUserInterfaceStyle.self, UITraitUserInterfaceLevel.self,
      UITraitAccessibilityContrast.self,
    ]) { (view: ChatSurfaceBackgroundView, _: UITraitCollection) in
      guard !view.isPromoting else { return }
      view.applyCurrentAppearance()
    }
    applyCurrentAppearance()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    let fade = min(fadeHeight, bounds.height)
    fill.frame = CGRect(x: 0, y: fade, width: bounds.width, height: bounds.height - fade)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fade)
    CATransaction.commit()
  }

  /// Capture the system's resolved sheet color before leaving its traits.
  func prepareForPromotion() {
    applyCurrentAppearance()
    isPromoting = true
  }

  func animatePromotion(to traits: UITraitCollection, duration: TimeInterval) {
    let color = UIColor.systemGroupedBackground.resolvedColor(with: traits)
    fill.backgroundColor = color
    let colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
    if fadeHeight > 0, duration > 0 {
      let animation = CABasicAnimation(keyPath: "colors")
      animation.fromValue = gradient.colors
      animation.toValue = colors
      animation.duration = duration
      animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      gradient.add(animation, forKey: "promotionColor")
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.colors = colors
    CATransaction.commit()
  }

  func finishPromotionAnimation() {
    gradient.removeAnimation(forKey: "promotionColor")
    // The expanded source is still a sheet until the workspace is ready.
    // Keep its destination color pinned through dismissal; resolving its
    // elevated traits here would flash gray before the workspace takes over.
  }

  private func applyCurrentAppearance() {
    let color = UIColor.systemGroupedBackground.resolvedColor(with: traitCollection)
    fill.backgroundColor = color
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradient.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
    CATransaction.commit()
  }

  static func inHierarchy(_ view: UIView) -> [ChatSurfaceBackgroundView] {
    (view as? ChatSurfaceBackgroundView).map { [$0] } ?? view.subviews.flatMap(inHierarchy)
  }
}
