import SwiftUI
import UIKit

/// A live system-color fill. During first send its color can animate with
/// the sheet's bounds instead of changing immediately when reparented.
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

  /// Capture the system's resolved sheet color before leaving its traits.
  func prepareForPromotion() {
    applyCurrentAppearance()
    isPromoting = true
  }

  /// Called inside the promotion's UIView animation, which animates the
  /// color change with the sheet's bounds.
  func animatePromotion(to traits: UITraitCollection) {
    backgroundColor = UIColor.systemGroupedBackground.resolvedColor(with: traits)
  }

  func finishPromotionAnimation() {
    // The expanded source is still a sheet until the workspace is ready.
    // Keep its destination color pinned through dismissal; resolving its
    // elevated traits here would flash gray before the workspace takes over.
  }

  private func applyCurrentAppearance() {
    backgroundColor = UIColor.systemGroupedBackground.resolvedColor(with: traitCollection)
  }

  static func inHierarchy(_ view: UIView) -> [ChatSurfaceBackgroundView] {
    (view as? ChatSurfaceBackgroundView).map { [$0] } ?? view.subviews.flatMap(inHierarchy)
  }
}
