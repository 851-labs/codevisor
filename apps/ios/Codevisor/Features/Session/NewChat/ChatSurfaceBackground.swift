import SwiftUI
import UIKit

struct ChatSurfaceBackground: UIViewRepresentable {
  func makeUIView(context _: Context) -> ChatSurfaceBackgroundView {
    ChatSurfaceBackgroundView()
  }

  func updateUIView(_: ChatSurfaceBackgroundView, context _: Context) {}
}

final class ChatSurfaceBackgroundView: UIView {
  private var isPromoting = false

  init() {
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
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

  func prepareForPromotion() {
    applyCurrentAppearance()
    isPromoting = true
  }

  func animatePromotion(to traits: UITraitCollection) {
    backgroundColor = UIColor.systemGroupedBackground.resolvedColor(with: traits)
  }

  func finishPromotionAnimation() {
  }

  private func applyCurrentAppearance() {
    backgroundColor = UIColor.systemGroupedBackground.resolvedColor(with: traitCollection)
  }

  static func inHierarchy(_ view: UIView) -> [ChatSurfaceBackgroundView] {
    (view as? ChatSurfaceBackgroundView).map { [$0] } ?? view.subviews.flatMap { inHierarchy($0) }
  }
}
