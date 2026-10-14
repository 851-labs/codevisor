import CodevisorUI
import SwiftUI
import UIKit

@MainActor
final class NewChatPresentationSession {
  private weak var presentedController: UIViewController?

  init(presentedController: UIViewController) {
    self.presentedController = presentedController
  }

  var liveView: UIView? { presentedController?.viewIfLoaded }

  var presentationCornerRadius: CGFloat {
    guard var view = presentedController?.viewIfLoaded else { return 32 }
    while !(view is UIWindow) {
      if view.layer.cornerRadius > 0 { return view.layer.cornerRadius }
      guard let superview = view.superview else { break }
      view = superview
    }
    return 32
  }

  var presentationWindow: UIWindow? {
    presentedController?.viewIfLoaded?.window
  }

  var presentingWindow: UIWindow? {
    presentedController?.presentingViewController?.viewIfLoaded?.window
  }

  var promotionHostWindow: UIWindow? {
    presentingWindow ?? presentationWindow
  }

  func visibleFrame(in window: UIWindow) -> CGRect? {
    guard let view = presentedController?.viewIfLoaded,
      !view.bounds.isEmpty
    else { return nil }
    return view.convert(view.bounds, to: window)
  }

  func dismissWithoutAnimation(completion: @escaping () -> Void) {
    guard let presentedController else {
      completion()
      return
    }
    UIView.performWithoutAnimation {
      presentedController.dismiss(animated: false, completion: completion)
    }
  }

}

@MainActor
struct NewChatPresentationReader: UIViewControllerRepresentable {
  let onResolve: (NewChatPresentationSession) -> Void

  func makeUIViewController(context _: Context) -> ResolverViewController {
    let controller = ResolverViewController()
    controller.onResolve = onResolve
    return controller
  }

  func updateUIViewController(
    _ controller: ResolverViewController,
    context _: Context
  ) {
    controller.onResolve = onResolve
    controller.resolveWhenReady()
  }

  @MainActor
  final class ResolverViewController: UIViewController {
    var onResolve: ((NewChatPresentationSession) -> Void)?
    private weak var resolvedController: UIViewController?

    override func loadView() {
      let view = UIView(frame: .zero)
      view.backgroundColor = .clear
      view.isUserInteractionEnabled = false
      view.accessibilityElementsHidden = true
      self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      resolveWhenReady()
    }

    func resolveWhenReady() {
      Task { @MainActor [weak self] in
        await Task.yield()
        self?.resolve()
      }
    }

    private func resolve() {
      guard let presented = enclosingPresentedController(),
        resolvedController !== presented
      else { return }
      resolvedController = presented
      IOSNavigationDiagnostics.record(
        "newChat.nativePresentation.resolved",
        "controller=\(String(describing: type(of: presented))) frame=\(NSCoder.string(for: presented.view.frame))"
      )
      onResolve?(NewChatPresentationSession(presentedController: presented))
    }

    private func enclosingPresentedController() -> UIViewController? {
      var candidate: UIViewController? = self
      var highestPresentedAncestor: UIViewController?
      while let controller = candidate {
        if controller.presentingViewController != nil {
          highestPresentedAncestor = controller
        }
        candidate = controller.parent
      }
      if let highestPresentedAncestor { return highestPresentedAncestor }

      guard let window = viewIfLoaded?.window,
        var controller = window.rootViewController
      else { return nil }
      while let presented = controller.presentedViewController,
        !presented.isBeingDismissed
      {
        controller = presented
      }
      guard controller !== window.rootViewController,
        view.isDescendant(of: controller.view)
      else { return nil }
      return controller
    }
  }
}

@MainActor
final class NewChatPromotionSurface {
  private weak var sourceWindow: UIWindow?
  private var liveView: UIView?
  private let container = UIView()
  private var animator: UIViewPropertyAnimator?
  private var navigationTitleTransition: NewChatNavigationTitleTransition?
  private(set) var didStartExpansion = false
  private let duration: TimeInterval
  private let editorHandoffID: UUID
  private var onExpanded: (() -> Void)?

  var isAnimatingNavigationTitle: Bool { navigationTitleTransition?.isAnimating == true }

  func transitionNavigationTitle(_ title: WorkspaceNavigationTitle, completion: @escaping () -> Void) {
    guard let navigationBar = liveView?.firstDescendant(where: { $0 is UINavigationBar }) as? UINavigationBar
    else { return }
    let transition = NewChatNavigationTitleTransition()
    navigationTitleTransition = transition
    transition.animate(in: navigationBar, title: title, duration: duration, completion: completion)
  }

  init(
    window: UIWindow,
    duration: TimeInterval,
    editorHandoffID: UUID,
    onExpanded: @escaping () -> Void
  ) {
    sourceWindow = window
    self.duration = duration
    self.editorHandoffID = editorHandoffID
    self.onExpanded = onExpanded
  }

  func expand(session: NewChatPresentationSession) {
    guard !didStartExpansion, let sourceWindow,
      let view = session.liveView,
      let sourceFrame = session.visibleFrame(in: sourceWindow),
      !sourceFrame.isEmpty
    else { return }
    didStartExpansion = true
    liveView = view
    let navigationBar = view.firstDescendant { $0 is UINavigationBar } as? UINavigationBar
    let sourceBarFrame = navigationBar.map { $0.convert($0.bounds, to: sourceWindow) }
    let sourceColor = UIColor.systemGroupedBackground.resolvedColor(with: view.traitCollection)
    let destinationTraits = sourceWindow.traitCollection
    let backgrounds = ChatSurfaceBackgroundView.inHierarchy(view)
    backgrounds.forEach { $0.prepareForPromotion() }
    container.frame = sourceFrame
    container.backgroundColor = sourceColor
    container.layer.cornerCurve = .continuous
    container.layer.cornerRadius = session.presentationCornerRadius
    container.clipsToBounds = true
    container.accessibilityViewIsModal = true
    sourceWindow.addSubview(container)

    container.addSubview(view)
    view.transform = .identity
    view.autoresizingMask = []
    view.frame = sourceWindow.bounds.offsetBy(dx: -sourceFrame.minX, dy: -sourceFrame.minY)
    UIView.performWithoutAnimation {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      container.layoutIfNeeded()
      if let navigationBar, let sourceBarFrame {
        let destinationBarFrame = navigationBar.convert(navigationBar.bounds, to: sourceWindow)
        navigationBar.transform = CGAffineTransform(
          translationX: 0, y: sourceBarFrame.minY - destinationBarFrame.minY)
      }
    }
    TranscriptSendStaging.shared.bringOverlaysToFront()

    let changes = {
      self.container.frame = sourceWindow.bounds
      self.container.backgroundColor = UIColor.systemGroupedBackground.resolvedColor(
        with: destinationTraits)
      view.frame = sourceWindow.bounds
      navigationBar?.transform = .identity
      backgrounds.forEach { $0.animatePromotion(to: destinationTraits) }
      self.container.layoutIfNeeded()
    }
    let finish = { [weak self] in
      backgrounds.forEach { $0.finishPromotionAnimation() }
      self?.container.layer.cornerRadius = 0
      IOSNavigationDiagnostics.record("newChat.promotionSurface.expanded")
      self?.onExpanded?()
    }
    guard duration > 0 else {
      UIView.performWithoutAnimation(changes)
      finish()
      return
    }
    let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut)
    self.animator = animator
    animator.addAnimations(changes)
    animator.addCompletion { [weak self] _ in
      self?.animator = nil
      finish()
    }
    animator.startAnimation()
  }

  @discardableResult
  func completeStableEditorHandoff() -> Bool {
    _ = ComposerTextViewHandoffRegistry.beginStablePortalTransition(id: editorHandoffID)
    return ComposerTextViewHandoffRegistry.completeStablePortalHandoff(id: editorHandoffID)
  }

  func remove() {
    navigationTitleTransition?.cancel()
    navigationTitleTransition = nil
    animator?.stopAnimation(true)
    animator = nil
    liveView?.removeFromSuperview()
    liveView = nil
    container.removeFromSuperview()
    sourceWindow = nil
    onExpanded = nil
  }
}
