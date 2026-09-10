import CodevisorUI
import SwiftUI
import UIKit

/// The native compose sheet stays live throughout its first-send expansion.
/// Its controller is dismissed only after the message has landed and the
/// canonical workspace can take over the same editor.
@MainActor
final class NewChatPresentationSession {
  private weak var presentedController: UIViewController?

  init(presentedController: UIViewController) {
    self.presentedController = presentedController
    // A conversation uses the same surface in its sheet and navigation
    // route. Elevated dark-mode system colors must not change at handoff.
    presentedController.traitOverrides.userInterfaceLevel = .base
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

  /// The stable app window that also hosts Home's navigation stack.
  var presentingWindow: UIWindow? {
    presentedController?.presentingViewController?.viewIfLoaded?.window
  }

  /// Where the promotion surface should live: the presenting window when
  /// it resolves, else the sheet's own.
  var promotionHostWindow: UIWindow? {
    presentingWindow ?? presentationWindow
  }

  /// The sheet's visible frame converted into an EXPLICIT window's
  /// coordinate space (UIKit converts across windows via screen space).
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

/// Resolves the real presentation controller from inside SwiftUI's `.sheet`.
/// It does not present or alter anything, preserving the platform's native
/// chrome, dimming, keyboard coordination, and drag gesture.
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

/// Expands the actual sheet hierarchy in its existing window. No image of
/// the transcript, composer, navigation bar, or backdrop is retained: every
/// pixel continues to come from the live controls and their current traits.
@MainActor
final class NewChatPromotionSurface {
  private weak var sourceWindow: UIWindow?
  private var liveView: UIView?
  private let container = UIView()
  private var animator: UIViewPropertyAnimator?
  private(set) var didStartExpansion = false
  private let duration: TimeInterval
  private let editorHandoffID: UUID
  private var onExpanded: (() -> Void)?

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
    container.frame = sourceFrame
    container.backgroundColor = .systemGroupedBackground
    container.traitOverrides.userInterfaceLevel = .base
    container.layer.cornerCurve = .continuous
    container.layer.cornerRadius = session.presentationCornerRadius
    container.clipsToBounds = true
    container.accessibilityViewIsModal = true
    sourceWindow.addSubview(container)

    // Reparent within the same UIWindow so the text view's first-responder
    // session and the live transcript survive. The sheet controller remains
    // alive until the normal workspace has mounted behind this hierarchy.
    container.addSubview(view)
    view.transform = .identity
    // Lay out once at the final window size. Resizing a hosting view while
    // its keyboard safe area is changing briefly pushes the composer below
    // the keyboard. Instead expand the clip around a stationary live view;
    // opposite container/content offsets keep its window position fixed.
    view.autoresizingMask = []
    view.frame = sourceWindow.bounds.offsetBy(dx: -sourceFrame.minX, dy: -sourceFrame.minY)
    UIView.performWithoutAnimation {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      container.layoutIfNeeded()
    }
    UserSendMorphCoordinator.shared.bringFlightToFront()

    let changes = {
      self.container.frame = sourceWindow.bounds
      view.frame = sourceWindow.bounds
      self.container.layer.cornerRadius = 0
      self.container.layoutIfNeeded()
    }
    let finish = { [weak self] in
      IOSNavigationDiagnostics.record("newChat.promotionSurface.expanded")
      self?.onExpanded?()
    }
    guard duration > 0 else {
      UIView.performWithoutAnimation(changes)
      finish()
      return
    }
    let animator = UIViewPropertyAnimator(
      duration: duration,
      timingParameters: TranscriptSendAnimationMetrics.propertyTimingParameters
    )
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
    // The editor stays visible inside the live composer during the flight.
    // Its window portal exists only for the final structural replacement.
    _ = ComposerTextViewHandoffRegistry.beginStablePortalTransition(id: editorHandoffID)
    return ComposerTextViewHandoffRegistry.completeStablePortalHandoff(id: editorHandoffID)
  }

  func remove() {
    animator?.stopAnimation(true)
    animator = nil
    liveView?.removeFromSuperview()
    liveView = nil
    container.removeFromSuperview()
    sourceWindow = nil
    onExpanded = nil
  }
}

extension UIView {
  /// Depth-first search of the subview tree.
  func firstDescendant(where predicate: (UIView) -> Bool) -> UIView? {
    for subview in subviews {
      if predicate(subview) { return subview }
      if let match = subview.firstDescendant(where: predicate) { return match }
    }
    return nil
  }
}
