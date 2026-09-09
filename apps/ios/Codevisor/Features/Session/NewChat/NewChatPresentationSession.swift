import CodevisorUI
import SwiftUI
import UIKit

/// A handle to the system-owned New Chat sheet. Compose, cancellation, and
/// interactive dismissal remain entirely system-owned. First-send promotion
/// uses a pixel overlay in the existing app window, so dismissing this
/// controller cannot introduce a second key-window or keyboard transition.
@MainActor
final class NewChatPresentationSession {
  private weak var presentedController: UIViewController?

  init(presentedController: UIViewController) {
    self.presentedController = presentedController
  }

  var visibleFrameInWindow: CGRect? {
    guard let view = presentedController?.viewIfLoaded,
      let window = view.window,
      !view.bounds.isEmpty
    else { return nil }
    return view.convert(view.bounds, to: window)
  }

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

  /// The PRESENTING side's window — the stable app window that hosts
  /// Home's navigation stack. Zoom-style sheet presentations can host the
  /// presented controller in a transient portal window; a promotion
  /// surface installed there can be detached from the render server,
  /// which completes its animator instantly (the "no animation" sends).
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

  /// The resting sheet's pixels as a bitmap, so the promotion surface can
  /// treat its navigation bar and its content separately.
  func snapshotImage() -> UIImage? {
    guard let view = presentedController?.viewIfLoaded, !view.bounds.isEmpty else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = view.window?.screen.scale ?? UIScreen.main.scale
    return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
      // The last presented frame is exactly what the user sees; the bubble
      // in flight is a separate window-level proxy that outlives the
      // bitmap, so nothing pending needs forcing through a synchronous
      // render here.
      view.drawHierarchy(in: view.bounds, afterScreenUpdates: false)
    }
  }

  /// Where the composer cluster begins, in the sheet's own coordinates —
  /// the boundary between transcript content (which the expansion slides)
  /// and the composer + keyboard (bottom-anchored in sheet and route alike).
  var composerTop: CGFloat? {
    guard let view = presentedController?.viewIfLoaded,
      let editor = view.firstDescendant(where: { $0 is ComposerTextViewContainer })
    else { return nil }
    // The card's chrome sits a little above the editor; cut in the blank
    // gap between the last row and the card so the seam is invisible.
    return editor.convert(editor.bounds, to: view).minY - 24
  }

  /// Where the sheet's navigation bar ends, in the sheet's own coordinates.
  var navigationBarBottom: CGFloat? {
    guard let view = presentedController?.viewIfLoaded,
      let bar = view.firstDescendant(where: { $0 is UINavigationBar })
    else { return nil }
    return bar.convert(bar.bounds, to: view).maxY
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
/// chrome, source zoom, dimming, keyboard coordination, and drag gesture.
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

/// A lightweight transition overlay in the app's EXISTING window. The native
/// sheet remains the true compose surface and Home's NavigationStack remains
/// the true destination; this owns only the pixels between them. Keeping one
/// UIWindow is essential: keyboard continuity is a responder-chain transfer,
/// whereas switching key windows is defined by UIKit as ending text entry.
///
/// The expansion is not a cross-dissolve. The live route sits underneath
/// from the start; over it, a bitmap of the resting sheet is split in two:
/// its content slides the few points into the route's content position and
/// simply vanishes once the two coincide, while its navigation-bar strip
/// fades out to reveal the route's bar — so the × glass circle stays put
/// and only its glyph turns into +, the title fades, and the back chevron
/// appears, as the sheet's top edge rises to fill the screen.
@MainActor
final class NewChatPromotionSurface {
  /// A normally-contained NavigationStack receives this compact-width
  /// gutter from UIKit. The promotion host temporarily lives directly in
  /// the existing window, so it must supply the same safe-area contract.
  /// WorkspaceScreen opts its body back out horizontally, leaving only the
  /// navigation chrome inset.
  static let navigationHorizontalInset: CGFloat = 16

  private weak var sourceWindow: UIWindow?
  private var liveContent: AnyView?
  private var liveHostingController: UIHostingController<AnyView>?
  private var contentImageView: UIImageView?
  private var composerImageView: UIImageView?
  private var barImageView: UIImageView?
  private let container = UIView()
  private let clippingView = UIView()
  private var animator: UIViewPropertyAnimator?
  private(set) var isReplicaPrepared = false
  private(set) var didStartExpansion = false
  private var sourceFrame = CGRect.zero
  private let duration: TimeInterval
  private let editorHandoffID: UUID
  private var onExpanded: (() -> Void)?

  init(
    window: UIWindow,
    duration: TimeInterval,
    editorHandoffID: UUID,
    liveContent: AnyView,
    onExpanded: @escaping () -> Void
  ) {
    sourceWindow = window
    self.duration = duration
    self.editorHandoffID = editorHandoffID
    self.liveContent = liveContent
    self.onExpanded = onExpanded
  }

  /// Mounts the route replica, hidden, while the sheet is still being
  /// composed. It renders the route's navigation chrome only — the bar
  /// the expansion reveals at the top and crossfades the sheet's bar into
  /// — over a flat background; the bitmap covers everything else until
  /// commit. Nothing in it depends on the send, so the expansion's own
  /// commit is instant when the moment comes.
  func prepareReplica() {
    guard !isReplicaPrepared,
      let sourceWindow,
      sourceWindow.bounds.width > 0,
      sourceWindow.bounds.height > 0,
      let liveContent
    else { return }
    isReplicaPrepared = true
    // This is a live visual replica, not another bitmap or UIWindow. It is
    // retained only for the morph; Home's already-mounted workspace route
    // owns every interaction and all navigation after completion.
    let hostingController = UIHostingController(rootView: liveContent)
    hostingController.additionalSafeAreaInsets = UIEdgeInsets(
      top: 0,
      left: Self.navigationHorizontalInset,
      bottom: 0,
      right: Self.navigationHorizontalInset
    )
    hostingController.view.frame = sourceWindow.bounds
    hostingController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    hostingController.view.backgroundColor = .clear
    hostingController.view.isUserInteractionEnabled = false
    // Above the sheet in the window, so hidden until the bitmap covers
    // the sheet and the expansion reveals it.
    hostingController.view.alpha = 0
    hostingController.beginAppearanceTransition(true, animated: false)
    sourceWindow.addSubview(hostingController.view)
    hostingController.endAppearanceTransition()
    liveHostingController = hostingController
    self.liveContent = nil
    hostingController.view.setNeedsLayout()
    hostingController.view.layoutIfNeeded()
    IOSNavigationDiagnostics.record("newChat.promotionSurface.replicaPrepared")
  }

  /// Covers the sheet with its resting bitmap, hands the editor into the
  /// window, and grows the bitmap into the route: content slides, the bar
  /// strip crossfades into the route's bar, the composer holds still.
  func expand(
    sourceFrame: CGRect,
    sourceCornerRadius: CGFloat,
    snapshot: UIImage?,
    barHeight: CGFloat,
    composerTop: CGFloat?
  ) {
    guard !didStartExpansion, !sourceFrame.isEmpty, let sourceWindow else { return }
    prepareReplica()
    didStartExpansion = true
    self.sourceFrame = sourceFrame

    let retainedResponder =
      ComposerTextViewHandoffRegistry
      .beginStablePortalTransition(id: editorHandoffID)
    IOSNavigationDiagnostics.record(
      "newChat.promotionSurface.sourceEditorCovered",
      "retained=\(retainedResponder)"
    )

    container.frame = sourceFrame
    container.backgroundColor = .clear
    // The card owns transition pixels only. All touches — including the
    // destination composer and NavigationStack's interactive edge pop —
    // must pass through to the live surface installed directly below it.
    container.isUserInteractionEnabled = false
    container.layer.shadowColor = UIColor.black.cgColor
    container.layer.shadowOpacity = 0.16
    container.layer.shadowRadius = 24
    container.layer.shadowOffset = CGSize(width: 0, height: -2)
    container.isAccessibilityElement = false

    clippingView.frame = container.bounds
    clippingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    clippingView.backgroundColor = .clear
    clippingView.layer.cornerCurve = .continuous
    clippingView.layer.cornerRadius = sourceCornerRadius
    clippingView.layer.masksToBounds = true
    if let snapshot, let cgImage = snapshot.cgImage {
      // All slices anchor to the container's bottom: a sheet that reaches
      // the screen bottom only ever grows at the TOP, so they stay
      // pixel-stationary while the top edge rises and reveals the route's
      // bar area beneath.
      let scale = snapshot.scale
      let width = snapshot.size.width
      let height = snapshot.size.height
      let bar = min(max(barHeight, 0), height)
      func slice(_ rect: CGRect) -> UIImageView {
        let pixels = CGRect(
          x: rect.minX * scale, y: rect.minY * scale,
          width: rect.width * scale, height: rect.height * scale)
        let view = UIImageView(
          image: cgImage.cropping(to: pixels).map {
            UIImage(cgImage: $0, scale: scale, orientation: .up)
          })
        view.frame = rect
        view.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        view.isUserInteractionEnabled = false
        return view
      }
      // Transcript content slides into the route's position; the composer
      // and keyboard below it are already where the route puts them, and
      // their slice overlaps the transcript's so the seam never opens.
      let transcriptBottom = min(max(composerTop ?? height, bar), height)
      let composerSliceTop = max(bar, transcriptBottom - 24)
      let content = slice(CGRect(x: 0, y: bar, width: width, height: transcriptBottom - bar))
      let composer = slice(
        CGRect(x: 0, y: composerSliceTop, width: width, height: height - composerSliceTop))
      let barStrip = slice(CGRect(x: 0, y: 0, width: width, height: bar))
      clippingView.addSubview(content)
      clippingView.addSubview(composer)
      clippingView.addSubview(barStrip)
      contentImageView = content
      composerImageView = composer
      barImageView = barStrip
    }
    container.addSubview(clippingView)
    sourceWindow.addSubview(container)
    container.layoutIfNeeded()
    // The bitmap now covers the sheet; the replica can show beneath it.
    liveHostingController?.view.alpha = 1

    let shift = contentShift
    let slide = CGAffineTransform(translationX: 0, y: -shift)
    let changes = {
      self.container.frame = sourceWindow.bounds
      self.clippingView.layer.cornerRadius = 0
      self.container.layer.shadowOpacity = 0
      self.container.layoutIfNeeded()
      self.contentImageView?.transform = slide
      self.barImageView?.transform = slide
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

    let startedAt = CACurrentMediaTime()
    IOSNavigationDiagnostics.record(
      "newChat.promotionSurface.expansionStart",
      "from=\(NSCoder.string(for: sourceFrame)) to=\(NSCoder.string(for: sourceWindow.bounds)) "
        + "shift=\(shift) bar=\(barHeight) key=\(sourceWindow.isKeyWindow)"
    )
    // A bubble still in flight rides the same slide, above the bitmap, and
    // stays as long as the bitmap does: the bitmap predates the landed row.
    UserSendMorphCoordinator.shared.bringFlightToFront()
    UserSendMorphCoordinator.shared.shiftFlight(by: -shift, duration: duration)
    UserSendMorphCoordinator.shared.beginExpansionHold()
    let animator = UIViewPropertyAnimator(
      duration: duration,
      timingParameters: TranscriptSendAnimationMetrics.propertyTimingParameters
    )
    self.animator = animator
    animator.addAnimations(changes)
    // Only the bar strip fades: the route's bar beneath is at (nearly) the
    // same place, so the glass circle holds still while × becomes +, the
    // title fades, and the chevron appears. Its own even curve keeps the
    // crossfade legible instead of riding the geometry's sharp ease-out.
    let barFade = UIViewPropertyAnimator(duration: duration * 0.7, curve: .easeInOut) {
      self.barImageView?.alpha = 0
    }
    barFade.startAnimation(afterDelay: duration * 0.15)
    animator.addCompletion { [weak self] position in
      IOSNavigationDiagnostics.record(
        "newChat.promotionSurface.expansionDone",
        "elapsedMs=\(Int((CACurrentMediaTime() - startedAt) * 1000)) position=\(position.rawValue)"
      )
      // The bitmap (and the bubble above it) stay put: the replica beneath
      // is chrome only, and Home's canonical route — pixel-identical to
      // this resting bitmap — is what `remove()` reveals at commit.
      self?.animator = nil
      finish()
    }
    animator.startAnimation()
    // Commit the animations to the render server NOW. The rest of this
    // turn mounts SwiftUI hierarchies (the replica's follow-up passes, the
    // canonical route), which would otherwise hold the expansion back a
    // few frames after the bubble has already taken off.
    CATransaction.flush()
    IOSNavigationDiagnostics.record(
      "newChat.promotionSurface.committed",
      "ms=\(Int((CACurrentMediaTime() - startedAt) * 1000))"
    )
  }

  /// How far the sheet's content must move up to sit where the route lays
  /// out the same content: the sheet's bar bottom versus the route's.
  private var contentShift: CGFloat {
    guard let routeView = liveHostingController?.view,
      let bar = routeView.firstDescendant(where: { $0 is UINavigationBar }),
      let barHeight = barImageView?.bounds.height
    else { return 0 }
    let routeContentTop = bar.convert(bar.bounds, to: routeView).maxY
    return (sourceFrame.minY + barHeight) - routeContentTop
  }

  private func removeBitmap() {
    contentImageView?.removeFromSuperview()
    contentImageView = nil
    composerImageView?.removeFromSuperview()
    composerImageView = nil
    barImageView?.removeFromSuperview()
    barImageView = nil
  }

  @discardableResult
  func completeStableEditorHandoff() -> Bool {
    let retained = ComposerTextViewHandoffRegistry.completeStablePortalHandoff(
      id: editorHandoffID
    )
    IOSNavigationDiagnostics.record(
      "newChat.promotionSurface.stableEditorHandoff",
      "retained=\(retained)"
    )
    return retained
  }

  func routeAccessibility(through session: NewChatPresentationSession?) {
    guard let sourceWindow, let liveView = liveHostingController?.view else { return }
    // Accessibility also treats the native sheet as modal. Override the
    // app-window container while promotion is active so VoiceOver sees
    // the same live navigation surface as sighted users. The keyboard is
    // hosted by its own system window and remains independently exposed.
    sourceWindow.accessibilityElements =
      [liveView]
      + (ComposerTextViewHandoffRegistry.promotedEditor(id: editorHandoffID)
        .map { [$0] } ?? [])
  }

  func remove() {
    animator?.stopAnimation(true)
    animator = nil
    UserSendMorphCoordinator.shared.endExpansionHold()
    removeBitmap()
    clippingView.removeFromSuperview()
    container.removeFromSuperview()
    if let liveHostingController {
      liveHostingController.beginAppearanceTransition(false, animated: false)
      liveHostingController.view.removeFromSuperview()
      liveHostingController.endAppearanceTransition()
    }
    liveHostingController = nil
    liveContent = nil
    sourceWindow?.accessibilityElements = nil
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
