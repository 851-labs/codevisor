import UIKit

struct WorkspaceNavigationTitle: Equatable {
  let title: String
  let subtitle: String
}

@MainActor
final class NewChatNavigationTitleTransition {
  private var animator: UIViewPropertyAnimator?
  private var outgoingTitle: UIView?
  private var incomingLabels: [UILabel] = []

  var isAnimating: Bool { animator != nil }

  func animate(
    in navigationBar: UINavigationBar,
    title: WorkspaceNavigationTitle,
    duration: TimeInterval,
    completion: @escaping () -> Void
  ) {
    guard let item = navigationBar.topItem else { return }
    navigationBar.layoutIfNeeded()
    let source = labels(in: navigationBar).first { $0.text == item.title }
    let snapshot = source?.snapshotView(afterScreenUpdates: false)
    if let source, let snapshot {
      snapshot.frame = source.convert(source.bounds, to: navigationBar)
      snapshot.isUserInteractionEnabled = false
      snapshot.accessibilityElementsHidden = true
    }

    UIView.performWithoutAnimation {
      item.title = title.title
      item.subtitle = title.subtitle
      item.style = .editor
      navigationBar.setNeedsLayout()
      navigationBar.layoutIfNeeded()
    }
    guard duration > 0, let snapshot else {
      completion()
      return
    }
    incomingLabels = labels(in: navigationBar).filter {
      $0.text == title.title || (!title.subtitle.isEmpty && $0.text == title.subtitle)
    }
    guard !incomingLabels.isEmpty else {
      completion()
      return
    }
    outgoingTitle = snapshot
    navigationBar.addSubview(snapshot)
    for label in incomingLabels {
      label.alpha = 0
      label.transform = CGAffineTransform(translationX: 0, y: 6)
    }
    let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
    self.animator = animator
    animator.addAnimations {
      snapshot.alpha = 0
      snapshot.transform = CGAffineTransform(translationX: 0, y: -4)
        .scaledBy(x: 0.96, y: 0.96)
      for label in self.incomingLabels {
        label.alpha = 1
        label.transform = .identity
      }
    }
    animator.addCompletion { [weak self] _ in
      self?.cancel()
      IOSNavigationDiagnostics.record("newChat.navigationTitle.finished")
      completion()
    }
    IOSNavigationDiagnostics.record("newChat.navigationTitle.started", "labels=\(incomingLabels.count)")
    animator.startAnimation()
  }

  func cancel() {
    if animator?.state == .active { animator?.stopAnimation(true) }
    animator = nil
    outgoingTitle?.removeFromSuperview()
    outgoingTitle = nil
    for label in incomingLabels {
      label.alpha = 1
      label.transform = .identity
    }
    incomingLabels = []
  }

  private func labels(in view: UIView) -> [UILabel] {
    if let label = view as? UILabel { return [label] }
    return view.subviews.flatMap { labels(in: $0) }
  }
}
