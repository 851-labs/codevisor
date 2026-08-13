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

    /// Preserve the exact final sheet pixels before first-send state replaces
    /// its SwiftUI hierarchy. This is a UIKit snapshot, not another live copy,
    /// so the outgoing text and native navigation chrome have one continuous
    /// visual owner while the destination mounts underneath them.
    func snapshotView(hidingComposerText: Bool = false) -> UIView? {
        guard let view = presentedController?.viewIfLoaded,
              !view.bounds.isEmpty
        else { return nil }
        let editor = hidingComposerText ? firstEditableTextView(in: view) : nil
        let previousAlpha = editor?.alpha
        editor?.alpha = 0
        let snapshot = view.snapshotView(afterScreenUpdates: false)
        if let previousAlpha { editor?.alpha = previousAlpha }
        return snapshot
    }

    private func firstEditableTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView, textView.isEditable { return textView }
        for subview in view.subviews {
            if let match = firstEditableTextView(in: subview) { return match }
        }
        return nil
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
                  !presented.isBeingDismissed {
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
    private var sourceSnapshot: UIView?
    private var outgoingFlightView: UIView?
    private var outgoingTarget: TranscriptSendAnimationTarget?
    private var outgoingPlan: TranscriptSendAnimationPlan?
    private var didResolveOutgoingTarget = false
    private let outgoingSourceEditorFrame: CGRect?
    private let container = UIView()
    private let clippingView = UIView()
    private var animator: UIViewPropertyAnimator?
    private var didInstall = false
    private var expansionRequested = false
    private var didStartExpansion = false
    private let sourceFrame: CGRect
    private let sourceCornerRadius: CGFloat
    private let duration: TimeInterval
    private let editorHandoffID: UUID
    private var onInstalled: (() -> Void)?
    private var onExpanded: (() -> Void)?

    init(
        window: UIWindow,
        sourceFrame: CGRect,
        sourceCornerRadius: CGFloat,
        duration: TimeInterval,
        editorHandoffID: UUID,
        sourceSnapshot: UIView?,
        outgoingSourceEditorFrame: CGRect?,
        liveContent: AnyView,
        onInstalled: @escaping () -> Void,
        onExpanded: @escaping () -> Void
    ) {
        sourceWindow = window
        self.sourceFrame = sourceFrame
        self.sourceCornerRadius = sourceCornerRadius
        self.duration = duration
        self.editorHandoffID = editorHandoffID
        self.sourceSnapshot = sourceSnapshot
        self.outgoingSourceEditorFrame = outgoingSourceEditorFrame
        self.liveContent = liveContent
        self.onInstalled = onInstalled
        self.onExpanded = onExpanded
    }

    func install() {
        guard !didInstall,
              !sourceFrame.isEmpty,
              let sourceWindow,
              sourceWindow.bounds.width > 0,
              sourceWindow.bounds.height > 0
        else { return }
        didInstall = true

        let retainedResponder = ComposerTextViewHandoffRegistry
            .beginStablePortalTransition(id: editorHandoffID)
        IOSNavigationDiagnostics.record(
            "newChat.promotionSurface.sourceEditorCovered",
            "retained=\(retainedResponder)"
        )

        // This is a live visual replica, not another bitmap or UIWindow. It is
        // retained only for the morph; Home's already-mounted workspace route
        // owns every interaction and all navigation after completion.
        if let liveContent {
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
            // The destination and source snapshot form a true cross-dissolve:
            // their opacities sum to one instead of drawing a fully opaque
            // destination beneath a fading source (which doubled every label
            // and control during the old transition).
            hostingController.view.alpha = sourceSnapshot == nil ? 1 : 0
            hostingController.beginAppearanceTransition(true, animated: false)
            sourceWindow.addSubview(hostingController.view)
            hostingController.endAppearanceTransition()
            liveHostingController = hostingController
            self.liveContent = nil
            hostingController.view.setNeedsLayout()
            hostingController.view.layoutIfNeeded()
        }

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
        // The snapshot supplies the opaque card during the animation. Once it
        // fades, transparency reveals the already-mounted real route below.
        clippingView.backgroundColor = .clear
        clippingView.layer.cornerCurve = .continuous
        clippingView.layer.cornerRadius = sourceCornerRadius
        clippingView.layer.masksToBounds = true
        if let sourceSnapshot {
            sourceSnapshot.frame = clippingView.bounds
            sourceSnapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            sourceSnapshot.isUserInteractionEnabled = false
            clippingView.addSubview(sourceSnapshot)
        }
        container.addSubview(clippingView)
        sourceWindow.addSubview(container)
        container.layoutIfNeeded()

        IOSNavigationDiagnostics.record(
            "newChat.promotionSurface.installed",
            "from=\(NSCoder.string(for: sourceFrame)) to=\(NSCoder.string(for: sourceWindow.bounds)) radius=\(sourceCornerRadius)"
        )
        onInstalled?()
    }

    func expand() {
        expansionRequested = true
        startExpansionIfReady()
    }

    private func startExpansionIfReady() {
        guard didInstall, expansionRequested, !didStartExpansion else { return }
        // A text send expands only once the already-mounted real destination
        // has supplied a snapshot of its final row. The snapshot is the exact
        // renderer ordinary sends animate; it is not a second bubble style.
        if outgoingSourceEditorFrame?.isEmpty == false,
           !didResolveOutgoingTarget { return }
        didStartExpansion = true
        guard let sourceWindow else {
            onExpanded?()
            return
        }
        let changes = {
            self.container.frame = sourceWindow.bounds
            self.clippingView.layer.cornerRadius = 0
            self.container.layer.shadowOpacity = 0
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

        installAndStartOutgoingFlight(in: sourceWindow)
        let animator = UIViewPropertyAnimator(
            duration: duration,
            timingParameters: TranscriptSendAnimationMetrics.propertyTimingParameters
        )
        self.animator = animator
        animator.addAnimations(changes)
        // Keep one opaque surface for most of the geometric transform. The
        // source and destination chrome occupy different coordinates, so a
        // full-duration cross-fade reads as duplicate buttons, labels, and
        // composer outlines. iMessage performs the semantic handoff at the
        // end of the sheet expansion, when those geometries nearly coincide.
        animator.addAnimations({
            self.sourceSnapshot?.alpha = 0
            self.liveHostingController?.view.alpha = 1
        }, delayFactor: 0.68)
        animator.addCompletion { [weak self] _ in
            self?.sourceSnapshot?.removeFromSuperview()
            self?.sourceSnapshot = nil
            self?.outgoingFlightView?.removeFromSuperview()
            self?.outgoingFlightView = nil
            self?.animator = nil
            finish()
        }
        animator.startAnimation()
    }

    /// The virtualizer reports the actual laid-out optimistic row, including
    /// its production SwiftUI renderer. We place that snapshot in the stable
    /// app-window coordinate space and apply the same translation/fade group
    /// used by an ordinary send. The expanding sheet cannot distort it.
    @discardableResult
    func setOutgoingMessageTarget(_ target: TranscriptSendAnimationTarget) -> Bool {
        didResolveOutgoingTarget = true
        guard duration > 0,
              let outgoingSourceEditorFrame,
              !outgoingSourceEditorFrame.isEmpty,
              let plan = TranscriptSendAnimationMetrics.plan(
                  sourceY: outgoingSourceEditorFrame.midY,
                  targetY: target.rowFrame.minY
              )
        else {
            outgoingTarget = nil
            outgoingPlan = nil
            startExpansionIfReady()
            return false
        }
        outgoingTarget = target
        outgoingPlan = plan
        startExpansionIfReady()
        return true
    }

    private func installAndStartOutgoingFlight(in sourceWindow: UIWindow) {
        guard outgoingFlightView == nil,
              let outgoingTarget,
              let outgoingPlan else { return }
        let flight = outgoingTarget.rowSnapshot
        flight.frame = outgoingTarget.rowFrame
        flight.isUserInteractionEnabled = false
        flight.accessibilityElementsHidden = true
        sourceWindow.addSubview(flight)
        flight.layer.add(
            TranscriptSendAnimationMetrics.layerAnimation(
                plan: outgoingPlan,
                fadesIn: true
            ),
            forKey: "codevisor.user-send"
        )
        outgoingFlightView = flight
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
        sourceWindow.accessibilityElements = [liveView]
            + (ComposerTextViewHandoffRegistry.promotedEditor(id: editorHandoffID)
                .map { [$0] } ?? [])
    }

    func remove() {
        animator?.stopAnimation(true)
        animator = nil
        sourceSnapshot?.removeFromSuperview()
        sourceSnapshot = nil
        outgoingFlightView?.removeFromSuperview()
        outgoingFlightView = nil
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
        onInstalled = nil
        onExpanded = nil
    }

}
