import CodevisorUI
import UIKit

/// Owns only the pixels between the workspace's pane and grid states. The
/// real WorkspaceScreen, NavigationStack, pane store, controllers, and
/// composer never move or duplicate during this animation.
@MainActor
final class WorkspaceTabZoomSurface {
    private weak var window: UIWindow?
    private var plan: WorkspaceTabZoomTransitionPlan
    private let direction: WorkspaceTabZoomDirection
    /// The source screen owns navigation/status/composer pixels while the
    /// fixed pane canvas moves above it.
    private let backdropView: UIView
    /// A stable, window-sized surface. Its bounds never participate in the
    /// animation; `maskView` is the independently morphing card aperture.
    private let surfaceView = UIView()
    private let maskView = UIView()
    /// Supplies the card shadow without coupling it to the clipping mask.
    private let shadowView = UIView()
    /// The snapshot's immutable coordinate system. Only a uniform affine
    /// scale and translation are animated—never its bounds or aspect ratio.
    private let canvasView = UIView()
    private let canvasContentView: UIView
    private let handoffDelayFactor: CGFloat
    private var animator: UIViewPropertyAnimator?
    private var completion: (() -> Void)?

    private init(
        window: UIWindow,
        backdropView: UIView,
        canvasContentView: UIView,
        plan: WorkspaceTabZoomTransitionPlan,
        direction: WorkspaceTabZoomDirection,
        handoffDelayFactor: CGFloat
    ) {
        self.window = window
        self.plan = plan
        self.direction = direction
        self.backdropView = backdropView
        self.canvasContentView = canvasContentView
        self.handoffDelayFactor = handoffDelayFactor
    }

    static func make(
        direction: WorkspaceTabZoomDirection,
        paneSnapshot: PaneTransitionSnapshot,
        cardFrame: CGRect,
        reduceMotion: Bool,
        handoffDelayFactor: CGFloat = WorkspaceTabZoomTransitionContract.handoffDelayFactor
    ) -> WorkspaceTabZoomSurface? {
        guard !reduceMotion,
            let window = activeWindow()
        else { return nil }

        let canvasContentView: UIView
        let canvasSize: CGSize
        if let transitionView = paneSnapshot.transitionView {
            canvasContentView = transitionView
            canvasSize = paneSnapshot.contentFrame.size
        } else if let paneImage = paneSnapshot.image {
            let imageView = UIImageView(image: paneImage)
            imageView.contentMode = .scaleToFill
            canvasContentView = imageView
            canvasSize = paneImage.size
        } else {
            return nil
        }

        guard
            let plan = WorkspaceTabZoomTransitionContract.plan(
                direction: direction,
                viewportFrame: paneSnapshot.contentFrame,
                cardFrame: cardFrame,
                canvasSize: canvasSize,
                reduceMotion: reduceMotion
            )
        else { return nil }

        let backdropView =
            paneSnapshot.backdropView
            ?? window.snapshotView(afterScreenUpdates: false)
            ?? fallbackSnapshotView(of: window)

        return WorkspaceTabZoomSurface(
            window: window,
            backdropView: backdropView,
            canvasContentView: canvasContentView,
            plan: plan,
            direction: direction,
            handoffDelayFactor: handoffDelayFactor
        )
    }

    func install() {
        guard let window else { return }

        backdropView.frame = window.bounds
        backdropView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdropView.isUserInteractionEnabled = false
        backdropView.accessibilityElementsHidden = true
        window.addSubview(backdropView)

        // While collapsing, cut the old full-size pane pixels out of the
        // backdrop. The moving canvas is then the only copy of the content,
        // and the newly mounted grid is progressively revealed behind it.
        if direction == .paneToGrid {
            backdropView.layer.mask = outsideMask(
                bounds: backdropView.bounds,
                hole: plan.source.maskFrame
            )
        }

        shadowView.backgroundColor = .systemGroupedBackground
        shadowView.isUserInteractionEnabled = false
        shadowView.accessibilityElementsHidden = true
        shadowView.layer.cornerCurve = .continuous
        shadowView.layer.shadowColor = UIColor.black.cgColor
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 4)
        shadowView.layer.shadowOpacity = direction == .gridToPane ? 0.14 : 0
        window.addSubview(shadowView)

        surfaceView.frame = window.bounds
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surfaceView.backgroundColor = .clear
        surfaceView.isUserInteractionEnabled = false
        surfaceView.accessibilityElementsHidden = true

        maskView.backgroundColor = .black
        maskView.layer.cornerCurve = .continuous
        surfaceView.mask = maskView

        canvasView.bounds = CGRect(origin: .zero, size: plan.canvasSize)
        // With a zero anchor point, `center` is the canvas's window-space
        // origin. This lets UIKit interpolate translation separately from the
        // uniform scale without ever deriving a new image layout.
        canvasView.layer.anchorPoint = .zero
        canvasView.backgroundColor = .clear
        canvasView.isUserInteractionEnabled = false
        canvasView.accessibilityElementsHidden = true

        canvasContentView.frame = canvasView.bounds
        canvasContentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasContentView.isUserInteractionEnabled = false
        canvasContentView.accessibilityElementsHidden = true
        canvasView.addSubview(canvasContentView)
        surfaceView.addSubview(canvasView)
        window.addSubview(surfaceView)

        apply(plan.source)
    }

    /// The collapsing pane is captured before the grid exists. Once SwiftUI
    /// measures the real card, update only the geometry plan while retaining
    /// those original pane pixels.
    func retarget(cardFrame: CGRect, reduceMotion: Bool) -> Bool {
        guard direction == .paneToGrid,
            let updatedPlan = WorkspaceTabZoomTransitionContract.plan(
                direction: direction,
                viewportFrame: plan.source.maskFrame,
                cardFrame: cardFrame,
                canvasSize: plan.canvasSize,
                reduceMotion: reduceMotion
            )
        else { return false }
        plan = updatedPlan
        return true
    }

    func animate(completion: @escaping () -> Void) {
        guard animator == nil else { return }
        self.completion = completion

        let animator = UIViewPropertyAnimator(
            duration: plan.duration,
            dampingRatio: WorkspaceTabZoomTransitionContract.dampingRatio
        )
        self.animator = animator
        animator.addAnimations {
            self.apply(self.plan.destination)
            self.shadowView.layer.shadowOpacity = self.direction == .paneToGrid ? 0.12 : 0
            self.backdropView.alpha = 0
        }
        // The fixed pixels hand off only after their geometry is essentially
        // identical to the live destination. This is a late dissolve, never a
        // mid-flight re-layout.
        animator.addAnimations(
            {
                self.surfaceView.alpha = 0
                self.shadowView.alpha = 0
            }, delayFactor: handoffDelayFactor)
        animator.addCompletion { [weak self] _ in
            self?.finish()
        }
        animator.startAnimation()
    }

    func cancel() {
        animator?.stopAnimation(true)
        finish()
    }

    private func finish() {
        animator = nil
        backdropView.removeFromSuperview()
        shadowView.removeFromSuperview()
        surfaceView.removeFromSuperview()
        let completion = completion
        self.completion = nil
        completion?()
    }

    private func apply(_ endpoint: WorkspaceTabZoomTransitionEndpoint) {
        maskView.frame = endpoint.maskFrame
        maskView.layer.cornerRadius = endpoint.cornerRadius
        shadowView.frame = endpoint.maskFrame
        shadowView.layer.cornerRadius = endpoint.cornerRadius
        canvasView.transform = CGAffineTransform(
            scaleX: endpoint.canvasScale,
            y: endpoint.canvasScale
        )
        canvasView.center = endpoint.canvasOrigin
    }

    private func outsideMask(bounds: CGRect, hole: CGRect) -> CAShapeLayer {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(rect: hole))
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path.cgPath
        mask.fillRule = .evenOdd
        return mask
    }

    private static func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private static func fallbackSnapshotView(of window: UIWindow) -> UIView {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleToFill
        return imageView
    }
}
