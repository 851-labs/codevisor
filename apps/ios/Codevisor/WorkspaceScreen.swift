import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

private struct PromotedHorizontalSafeAreaExpansion: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.ignoresSafeArea(.container, edges: .horizontal)
        } else {
            content
        }
    }
}

// MARK: - Pane persistence

/// Client-side persistence of each workspace's panes, reusing the shared
/// `PaneGroupState`/`PaneDescriptorState` model — including the
/// `"<sessionUuid>:<paneUuid>"` terminal-key scheme, so pane PTYs are keyed
/// identically to macOS. Returning to a workspace restores the same panes
/// with the same pane selected.
@MainActor
@Observable
final class WorkspacePaneStore {
    static let shared = WorkspacePaneStore()

    private var cache: [UUID: PaneGroupState] = [:]

    private func key(for id: UUID) -> String {
        "ios.workspace.panes.\(id.uuidString)"
    }

    /// Pane state belongs to the workspace, not whichever chat happened to
    /// route into it. `legacySessionIds` migrates layouts written before iOS
    /// learned about multi-chat workspaces, when the storage key was the
    /// routed session id.
    func state(for workspaceId: UUID, legacySessionIds: [UUID] = []) -> PaneGroupState {
        if let cached = cache[workspaceId] { return cached }
        if let data: Data = ClientPreferences.shared.valueIfPresent(
            forKey: key(for: workspaceId)
        ),
           let decoded = try? JSONDecoder().decode(PaneGroupState.self, from: data) {
            cache[workspaceId] = decoded
            return decoded
        }

        // A later chat-row tap in an old build may have created a second,
        // one-chat legacy state. Prefer the richest candidate so the original
        // workspace (with its terminals and sibling chats) wins migration.
        let legacy = legacySessionIds
            .filter { $0 != workspaceId }
            .compactMap { existingState(for: $0) }
            .max { $0.panes.count < $1.panes.count }
        if let decoded = legacy {
            save(decoded, for: workspaceId)
            return decoded
        }

        let initialSessionId = legacySessionIds.first ?? workspaceId
        let initial = PaneGroupState.centerInitial(sessionId: initialSessionId)
        cache[workspaceId] = initial
        return initial
    }

    /// Existing state only—used to discover relationships written by older
    /// iOS versions without manufacturing new pane groups during a backfill.
    func existingState(for id: UUID) -> PaneGroupState? {
        if let cached = cache[id] { return cached }
        guard let data: Data = ClientPreferences.shared.valueIfPresent(forKey: key(for: id)),
              let decoded = try? JSONDecoder().decode(PaneGroupState.self, from: data)
        else { return nil }
        cache[id] = decoded
        return decoded
    }

    func save(_ state: PaneGroupState, for workspaceId: UUID) {
        cache[workspaceId] = state
        if let data = try? JSONEncoder().encode(state) {
            ClientPreferences.shared.set(data, forKey: key(for: workspaceId))
        }
    }

    /// A chat-row tap is an explicit request for that chat, so select its pane
    /// before Home pushes the workspace. If the shared workspace knows about a
    /// chat that this device has never rendered, add its iOS tab on demand.
    func selectChat(
        _ sessionId: UUID,
        in workspaceId: UUID,
        legacySessionIds: [UUID]
    ) {
        var state = state(for: workspaceId, legacySessionIds: legacySessionIds)
        if let pane = state.panes.first(where: {
            $0.kind == .chat && $0.chatSessionId == sessionId
        }) {
            state.selectPane(id: pane.id)
        } else {
            _ = state.addChatPane(sessionId: sessionId)
        }
        save(state, for: workspaceId)
    }
}

/// Safari-style tab previews: the visible pane is snapshotted (with the app's
/// own navigation chrome cropped off) when the grid opens. Real previews are
/// retained in memory and persisted as stale-while-revalidate images, so a
/// relaunch can paint the grid before any live transcript reconnects.
struct PaneTransitionSnapshot {
    let image: UIImage?
    /// The pane-owned content rectangle in window coordinates. Navigation
    /// chrome and the chat composer deliberately live outside it.
    let contentFrame: CGRect
    /// Render-server-backed views are cheap to create and retain their pixels
    /// without synchronously rasterizing the whole window. They exist only
    /// for the transition that captured them; the image remains the durable
    /// card-preview cache.
    let transitionView: UIView?
    let backdropView: UIView?
}

@MainActor
@Observable
final class PaneSnapshotCache {
    static let shared = PaneSnapshotCache()
    private(set) var images: [WorkspacePanePreviewKey: UIImage] = [:]
    @ObservationIgnored private var attemptedDiskLoads: Set<WorkspacePanePreviewKey> = []
    @ObservationIgnored private let diskStore: WorkspacePanePreviewDiskStore
    /// The visible chat pane's composer-stack height, written by the pane
    /// body so captures can crop it. (Plain storage, not a SwiftUI
    /// preference: preferences fed back into navigation state cancel
    /// in-flight push transitions.)
    var activeBottomChrome: CGFloat = 0

    init(
        diskStore: WorkspacePanePreviewDiskStore = WorkspacePanePreviewDiskStore(
            directory: CodevisorAppVariant.applicationSupportURL()
                .appendingPathComponent("Pane Previews", isDirectory: true)
        )
    ) {
        self.diskStore = diskStore
    }

    func image(for paneId: UUID, in workspaceId: UUID) -> UIImage? {
        images[WorkspacePanePreviewKey(workspaceId: workspaceId, paneId: paneId)]
    }

    /// Loads durable stale images without waiting for any pane controller or
    /// server. Missing entries are remembered for this run so ordinary view
    /// updates do not repeatedly touch disk.
    func loadPersistedPreviews(workspaceId: UUID, paneIds: [UUID]) async {
        let keys = paneIds.map {
            WorkspacePanePreviewKey(workspaceId: workspaceId, paneId: $0)
        }.filter { key in
            images[key] == nil && !attemptedDiskLoads.contains(key)
        }
        guard !keys.isEmpty else { return }
        attemptedDiskLoads.formUnion(keys)

        let bytes = await diskStore.data(for: keys)
        guard !Task.isCancelled else { return }
        for key in keys {
            guard let data = bytes[key] else { continue }
            if let image = UIImage(data: data) {
                images[key] = image
            } else {
                // A truncated or unsupported cache file is disposable. Never
                // let it poison future launches or block the fallback zoom.
                try? await diskStore.remove(key)
            }
        }
    }

    func store(
        _ image: UIImage,
        for paneId: UUID,
        in workspaceId: UUID,
        persist: Bool = true
    ) {
        let key = WorkspacePanePreviewKey(
            workspaceId: workspaceId,
            paneId: paneId
        )
        images[key] = image
        attemptedDiskLoads.insert(key)
        guard persist else { return }

        let diskStore = diskStore
        Task {
            let data = await Task.detached(priority: .utility) {
                image.pngData()
            }.value
            guard let data else { return }
            try? await diskStore.save(data, for: key)
        }
    }

    func remove(paneId: UUID, from workspaceId: UUID) {
        let key = WorkspacePanePreviewKey(
            workspaceId: workspaceId,
            paneId: paneId
        )
        images[key] = nil
        attemptedDiskLoads.insert(key)
        let diskStore = diskStore
        Task { try? await diskStore.remove(key) }
    }

    /// `bottomChrome` is the height of pane-owned chrome above the safe area
    /// (the chat composer) to exclude, so previews show only content.
    @discardableResult
    func captureKeyWindow(
        for paneId: UUID,
        in workspaceId: UUID,
        bottomChrome: CGFloat = 0
    ) -> PaneTransitionSnapshot? {
        guard let window = activeWindow else { return nil }
        let contentFrame = contentFrame(in: window, bottomChrome: bottomChrome)
        let transitionView = window.resizableSnapshotView(
            from: contentFrame,
            afterScreenUpdates: false,
            withCapInsets: .zero
        )
        let backdropView = window.snapshotView(afterScreenUpdates: false)

        // Card previews need only card-quality pixels. Rendering the clipped
        // content at 2x avoids the previous 3x full-window allocation while
        // remaining sharp in the two-column grid.
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, window.screen.scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: contentFrame.size, format: format)
        let image = renderer.image { _ in
            window.drawHierarchy(
                in: window.bounds.offsetBy(
                    dx: -contentFrame.minX,
                    dy: -contentFrame.minY
                ),
                afterScreenUpdates: false
            )
        }
        store(image, for: paneId, in: workspaceId)
        return PaneTransitionSnapshot(
            image: image,
            contentFrame: contentFrame,
            transitionView: transitionView,
            backdropView: backdropView
        )
    }

    func transitionSnapshot(
        for paneId: UUID,
        in workspaceId: UUID,
        bottomChrome: CGFloat = 0
    ) -> PaneTransitionSnapshot? {
        guard let window = activeWindow else { return nil }
        return PaneTransitionSnapshot(
            image: image(for: paneId, in: workspaceId),
            contentFrame: contentFrame(in: window, bottomChrome: bottomChrome),
            transitionView: nil,
            backdropView: nil
        )
    }

    private var activeWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func contentFrame(in window: UIWindow, bottomChrome: CGFloat) -> CGRect {
        // Read the actual bar geometry rather than assuming the historical
        // 44pt height. Current iOS navigation chrome is taller, and even a
        // small mismatch is conspicuous when the zoom begins.
        let navigationBottom = visibleNavigationBarBottom(in: window)
            ?? window.safeAreaInsets.top + 44
        let bottomInset = bottomChrome > 0
            ? bottomChrome + window.safeAreaInsets.bottom
            : 0
        return CGRect(
            x: window.bounds.minX,
            y: navigationBottom,
            width: window.bounds.width,
            height: max(1, window.bounds.maxY - navigationBottom - bottomInset)
        )
    }

    private func visibleNavigationBarBottom(in root: UIView) -> CGFloat? {
        var bottoms: [CGFloat] = []
        func visit(_ view: UIView) {
            if let bar = view as? UINavigationBar,
               !bar.isHidden,
               bar.alpha > 0.01,
               let window = bar.window {
                let frame = bar.convert(bar.bounds, to: window)
                if frame.height > 0, frame.intersects(window.bounds) {
                    bottoms.append(frame.maxY)
                }
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return bottoms.max()
    }
}

// MARK: - Workspace-local tab zoom

private struct PaneCardFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

/// Motion shared by every in-grid mutation. The lifted preview and the empty
/// slot are separate layers, so these springs never stretch or reflow card
/// contents.
private enum WorkspaceTabGridMotion {
    static let lift = Animation.interactiveSpring(
        response: 0.18,
        dampingFraction: 0.88,
        blendDuration: 0.03
    )
    static let reorder = Animation.interactiveSpring(
        response: 0.24,
        dampingFraction: 0.86,
        blendDuration: 0.06
    )
    static let removal = Animation.interactiveSpring(
        response: 0.28,
        dampingFraction: 0.9,
        blendDuration: 0.04
    )
    static let release = Animation.interactiveSpring(
        response: 0.3,
        dampingFraction: 0.88,
        blendDuration: 0.05
    )
}

/// The grid owns this lifted surface from long-press through release. Unlike
/// a system drag preview, it can land on the moving empty slot before the
/// canonical card is revealed, so there is no fade/pop or lost-delegate race.
private struct WorkspaceTabGridDragState {
    let pane: PaneDescriptorState
    let title: String
    let snapshot: UIImage?
    let size: CGSize
    let grabOffset: CGSize
    /// Slot geometry is frozen at pickup. Live card frames animate after
    /// every reorder and must never become moving hit-test thresholds.
    let slots: [WorkspaceTabGridSlot]
    var currentSlotIndex: Int
    var fingerLocation: CGPoint
    var liftProgress: CGFloat
}

/// Owns only the pixels between the workspace's pane and grid states. The
/// real WorkspaceScreen, NavigationStack, pane store, controllers, and
/// composer never move or duplicate during this animation.
@MainActor
private final class WorkspaceTabZoomSurface {
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

        guard let plan = WorkspaceTabZoomTransitionContract.plan(
                  direction: direction,
                  viewportFrame: paneSnapshot.contentFrame,
                  cardFrame: cardFrame,
                  canvasSize: canvasSize,
                  reduceMotion: reduceMotion
              )
        else { return nil }

        let backdropView = paneSnapshot.backdropView
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
        animator.addAnimations({
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

// MARK: - Workspace screen

/// A workspace: one full-screen pane (tab) at a time — chats, terminals, and
/// the new-tab page — with a Safari-style grid to switch, add, and close
/// them. The nav bar shows the active pane's title between a sidebar button
/// (back to the workspace list) and the tab-grid button; chat panes hide
/// their title so the transcript scrolls clear off the top.
struct WorkspaceScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.displayScale) private var displayScale
    /// The workspace's chat, or nil while the native New Chat sheet owns the
    /// draft composer. Its first send adopts a real session in place; Home then
    /// mounts an ordinary workspace route backed by the same cached controller
    /// before removing the opaque sheet.
    let sessionId: UUID?
    /// Machine identity is part of a session's key. The same server database
    /// can be visible through both a direct/local registration and Codevisor
    /// Cloud, so UUID alone is intentionally insufficient for lookups.
    var serverId: String? = nil
    /// Stable workspace identity for normal routes. Agent rows also supply a
    /// preferred chat; workspace rows leave it nil so the last-open tab wins.
    var workspaceId: UUID? = nil
    var preferredChatSessionId: UUID? = nil
    /// Existing workspaces receive their cached-or-new controller from Home
    /// during destination construction, so the transcript shell is available
    /// on the first frame instead of waiting for this view's async task.
    var initialController: SessionController? = nil
    /// New Chat is hosted by a real system sheet. This flag changes only the
    /// navigation controls; presentation chrome remains system-owned.
    var isNewChatPresentation = false
    /// The first-send overlay is an independently hosted copy of the real
    /// workspace. It temporarily uses the sheet's post-send navigation chrome
    /// while the native modal is removed underneath it.
    var isFirstSendPromotionSurface = false
    /// A one-shot request created when Home begins presenting New Chat. It is
    /// carried to the UIKit editor without being regenerated by view updates.
    var initialComposerFocusRequest: UUID? = nil
    /// Clears the request at its source after UIKit accepts it. Keeping this
    /// acknowledgement above the destination means even an unexpected
    /// composer remount cannot focus the keyboard a second time.
    var onInitialComposerFocusRequestFulfilled: ((UUID) -> Void)? = nil
    /// The first send has minted a real session. HomeView mounts an ordinary
    /// workspace route beneath the sheet.
    var onDraftStarted: ((UUID) -> Void)? = nil
    /// The no-project browser pushes into the sheet's type-erased path. Once a
    /// folder is selected, Home removes only those browser entries.
    var onInitialProjectAdded: (() -> Void)? = nil
    /// Home owns the native sheet's Boolean presentation state, so the close
    /// button requests dismissal there. Normal workspace routes keep using
    /// the environment dismiss action.
    var onDismissNewChat: (() -> Void)? = nil
    /// A normal workspace destination reports when its cached transcript has
    /// mounted. Home uses this to remove the opaque sheet without exposing a
    /// spinner or an intermediate navigation frame.
    var onWorkspaceReady: ((UUID) -> Void)? = nil
    /// A destination mounted beneath a promoted New Chat may prepare its
    /// transcript, but the still-visible sheet remains the presentation and
    /// scroll owner until Home commits the handoff.
    var transcriptPresentationRole: TranscriptPresentationRole = .foreground
    var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)? = nil
    var onSendAnimationStarted: ((
        UserSendAnimationRequest,
        TranscriptSendAnimationTarget
    ) -> Bool)? = nil
    var onComposerWillSend: ((String, CGRect) -> Void)? = nil
    /// The temporary promotion host supplies UIKit's missing horizontal safe
    /// area so its navigation controls use normal compact-width gutters. The
    /// workspace body ignores only that temporary inset and remains full
    /// width, matching every ordinary chat route.
    var extendsUnderPromotedHorizontalSafeArea = false
    var composerTextEditorHandoffRole: ComposerTextEditorHandoffRole = .none
    var composerTextEditorHandoffID: UUID? = nil

    /// One controller per chat session shown in this workspace (macOS allows
    /// several chats per workspace; so do we).
    @State private var controllers: [UUID: SessionController] = [:]
    @State private var missing = false
    @State private var serverConfig: CodevisorServerConfig?
    @State private var project: Project?
    @State private var paneState: PaneGroupState?
    /// Set when a draft's first send creates its session. From then on this
    /// screen is that workspace — same view, same pane, same transcript.
    @State private var startedSessionId: UUID?
    /// The retained draft controller while `sessionId` is nil.
    @State private var draftController: SessionController?
    /// The draft's first send landed: the run pickers collapse away.
    @State private var hasStarted = false
    /// Stands in for the session id a draft doesn't have yet, so its pane
    /// group can exist (and keep a STABLE pane id) from the first frame.
    @State private var draftPlaceholderId = UUID()
    /// The tab grid is workspace-local state, not another navigation
    /// destination. Keeping the active pane in Home's NavigationStack means
    /// the system back button and edge swipe always pop straight to Home.
    @State private var showsGrid = false
    /// Measured card endpoints for the snapshot-only tab zoom. These are
    /// visual coordinates, never navigation or pane state.
    @State private var paneCardFrames: [UUID: CGRect] = [:]
    /// Non-nil only while UIKit owns a native drag session for this card.
    /// Pane order itself always changes through `paneBinding`, so every live
    /// displacement is immediately durable and survives an interrupted drag.
    @State private var gridDrag: WorkspaceTabGridDragState?
    @State private var suppressedPaneTapId: UUID?
    /// GestureState resets on both normal completion and system cancellation,
    /// giving the lifted card one authoritative release/cleanup signal.
    @GestureState private var gridDragGestureIsActive = false
    @State private var gridLiftFeedback = 0
    @State private var pendingGridZoomPaneId: UUID?
    /// Safari inserts the new tab into the grid first, then expands that
    /// card. Keeping this separate from `pendingGridZoomPaneId` makes the
    /// source of each transition explicit: an existing pane collapses into
    /// the grid, while a newly-created placeholder expands out of it.
    @State private var pendingNewTabZoomPaneId: UUID?
    @State private var tabZoomSurface: WorkspaceTabZoomSurface?

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    /// This workspace's chat: the routed one, or the one a draft's first send
    /// created. Nil only while an unsent draft.
    private var activeSessionId: UUID? { sessionId ?? startedSessionId }

    private var isDraft: Bool { activeSessionId == nil }

    private var resolvedServerId: String {
        serverId ?? draftController?.project.serverId ?? environment.machines.selectedMachineId
    }

    private var resolvedWorkspace: Workspace? {
        if let workspaceId,
           let workspace = environment.workspaces.loadAll().first(where: {
               $0.serverId == resolvedServerId && $0.id == workspaceId
           }) {
            return workspace
        }
        guard let activeSessionId else { return nil }
        return environment.workspaces.loadAll().first {
            $0.serverId == resolvedServerId && $0.chatSessionIds.contains(activeSessionId)
        }
    }

    private var paneStorageId: UUID? {
        resolvedWorkspace?.id ?? activeSessionId
    }

    private var panePreviewLoadToken: String {
        guard let paneStorageId else { return "draft" }
        return ([paneStorageId] + panes.panes.map(\.id))
            .map(\.uuidString)
            .joined(separator: ":")
    }

    private var legacyPaneSessionIds: [UUID] {
        let workspaceIds = resolvedWorkspace?.chatSessionIds ?? []
        guard let activeSessionId else { return workspaceIds }
        return [activeSessionId] + workspaceIds.filter { $0 != activeSessionId }
    }

    private var panes: PaneGroupState {
        if let paneState { return paneState }
        if let paneStorageId {
            return WorkspacePaneStore.shared.state(
                for: paneStorageId,
                legacySessionIds: legacyPaneSessionIds
            )
        }
        // A draft's pane exists before its session does, keyed by a
        // placeholder so its id — and therefore the chat view's identity —
        // survives the session being adopted.
        return PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
    }

    private var activePane: PaneDescriptorState? {
        panes.selectedPane ?? panes.panes.first
    }

    private func session(for id: UUID) -> ChatSession? {
        environment.projectList.sessions.first {
            $0.serverId == resolvedServerId && $0.id == id
        }
    }

    private var rootSession: ChatSession? { activeSessionId.flatMap(session(for:)) }

    /// The persisted project snapshot is good enough to construct New Chat's
    /// draft immediately. The server refresh that follows may update this
    /// list, but it must not hold the sheet behind a loading surface.
    private var draftProjectCandidate: Project? {
        environment.projectList.activeProjects.first { !$0.isScratch }
    }

    /// The workspace's project. `prepare()` caches it in state, but it also
    /// resolves synchronously from the already-loaded project list, so the
    /// first frame renders the pane instead of a spinner — arriving from a new
    /// chat's first send must show the chat, not a placeholder.
    private var resolvedProject: Project? {
        project
            ?? draftController?.project
            ?? rootSession.flatMap { session in
                environment.projectList.projects.first {
                    $0.serverId == session.serverId && $0.id == session.projectId
                }
            }
    }

    /// The app-wide cached controller for a chat, if it already exists — no
    /// creation, so this is safe to call straight from the view body.
    private func cachedController(for chatId: UUID) -> SessionController? {
        guard let session = session(for: chatId) else { return nil }
        return ChatControllerCache.shared.existingController(
            sessionId: chatId,
            serverId: session.serverId
        )
    }

    /// The controller a chat pane shows. A draft's pane is served by the
    /// retained draft controller — the SAME controller the session adopts, so
    /// nothing about the view changes when the send lands.
    private func chatController(for pane: PaneDescriptorState) -> SessionController? {
        guard let chatId = pane.chatSessionId ?? activeSessionId else { return draftController }
        if chatId == draftPlaceholderId { return draftController }
        if let controller = controllers[chatId] { return controller }
        if chatId == sessionId, let initialController { return initialController }
        return cachedController(for: chatId)
    }

    private func title(for pane: PaneDescriptorState) -> String {
        switch pane.kind {
        case .chat:
            let title = (pane.chatSessionId ?? activeSessionId)
                .flatMap(session(for:))?.title ?? pane.name
            return title.isEmpty ? "New Chat" : title
        case .newTab:
            return "New Tab"
        case .terminal:
            return pane.name
        }
    }

    private var workspaceCwd: String {
        rootSession?.cwd
            ?? resolvedProject?.folderURL.path
            ?? ""
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()
            workspaceContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(
            PromotedHorizontalSafeAreaExpansion(
                isEnabled: extendsUnderPromotedHorizontalSafeArea
            )
        )
        .allowsHitTesting(
            tabZoomSurface == nil && pendingNewTabZoomPaneId == nil
        )
    }

    private var workspaceContent: some View {
        Group {
            if blocksServerContent {
                let machine = environment.machines.selectedMachine
                ServerAvailabilityView(
                    machineId: machine.id,
                    availability: environment.machines.selectedServerAvailability,
                    machineName: machine.name,
                    isLocal: false
                ) {
                    Task { await environment.machines.retrySelectedMachine() }
                }
            } else if missing {
                ContentUnavailableView("Chat Not Found", systemImage: "questionmark.bubble")
            } else if isDraft, draftController == nil {
                if draftProjectCandidate == nil {
                    // Match macOS's stale-while-revalidate behavior: an empty
                    // persisted snapshot opens project setup immediately. If
                    // the background refresh finds a project, onChange below
                    // replaces this with the draft composer.
                    initialProjectPicker
                } else {
                    // setUpDraftIfNeeded() runs synchronously at the start of
                    // prepare(). Keep the sheet calm for that initial actor
                    // turn rather than flashing either setup or a spinner.
                    Color.clear
                }
            } else if resolvedProject == nil {
                DelayedWorkspaceLoadingView()
            } else if preferredChatSessionId != nil, paneState == nil {
                // An agent-row tap is an explicit route. Do not paint the
                // workspace's previously selected terminal/chat while the
                // destination task applies the requested pane.
                DelayedWorkspaceLoadingView()
            } else if showsGrid {
                grid
            } else if let pane = activePane {
                paneContent(pane)
                    .id(pane.id)
            }
        }
        // Native navigation back to the workspaces list: the system back
        // button and the edge swipe-to-go-back gesture. Hiding the back
        // button for a custom sidebar button disabled the interactive pop.
        // The exception is the tab grid: its back affordance returns to the
        // last-open tab, because the grid is workspace-local navigation.
        .navigationBarBackButtonHidden(showsGrid)
        .navigationTitle(baseTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsGrid, !isNewChatPresentation {
                    Button {
                        reopenSelectedPane()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back to selected tab")
                } else if isNewChatPresentation,
                          hasStarted || isFirstSendPromotionSurface {
                    Button {
                        dismissNewChatPresentation()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Agents")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isNewChatPresentation, !hasStarted, !isFirstSendPromotionSurface {
                    Button {
                        dismissNewChatPresentation()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Cancel")
                // Tabs belong to a workspace; an unsent draft has none yet.
                } else if !blocksServerContent, !isDraft {
                    if showsGrid {
                        Button {
                            addTab()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New tab")
                    } else {
                        Button {
                            if let pane = activePane { showGrid(from: pane) }
                        } label: {
                            Image(systemName: "square.on.square")
                        }
                        .accessibilityLabel("Show tabs")
                    }
                }
            }
        }
        // Folder traversal only exists in the unsent-draft sheet. Registering
        // its route from an ordinary workspace also injects RemoteDirectory
        // into Home's homogeneous HomeRoute stack, which SwiftUI rejects and
        // can leave the navigation bar in an invalid transition state.
        .modifier(
            InitialProjectNavigationDestination(
                isEnabled: isNewChatPresentation,
                onPick: addInitialProject
            )
        )
        .task(id: environment.machines.selectedServerAvailability) {
            guard case .ready = environment.machines.selectedServerAvailability else { return }
            await prepare()
        }
        .task(id: panePreviewLoadToken) {
            guard let paneStorageId else { return }
            await PaneSnapshotCache.shared.loadPersistedPreviews(
                workspaceId: paneStorageId,
                paneIds: panes.panes.map(\.id)
            )
        }
        .onChange(of: environment.machines.selectedServerAvailability) { _, availability in
            if case .ready = availability { return }
            showsGrid = false
        }
        .onChange(of: environment.projectList.activeProjects.map(\.id)) { _, _ in
            setUpDraftIfNeeded()
        }
        .iosNavigationDiagnostics(navigationDiagnosticState)
    }

    private var blocksServerContent: Bool {
        if case .ready = environment.machines.selectedServerAvailability {
            return false
        }
        return true
    }

    private var navigationDiagnosticState: IOSNavigationDiagnosticState {
        let identifier = workspaceId ?? activeSessionId ?? draftPlaceholderId
        let contentPhase: String
        if blocksServerContent {
            contentPhase = "server-blocked"
        } else if isDraft {
            contentPhase = draftController == nil ? "draft-missing" : "draft-ready"
        } else if let pane = activePane, pane.kind == .chat {
            if let controller = chatController(for: pane) {
                if controller.model != nil {
                    contentPhase = "model-ready"
                } else if controller.isConnecting {
                    contentPhase = "connecting"
                } else if controller.isLoadingInitialHistory {
                    contentPhase = "history-loading-idle"
                } else {
                    contentPhase = "model-missing-idle"
                }
            } else {
                contentPhase = "controller-missing"
            }
        } else {
            contentPhase = "non-chat"
        }
        return IOSNavigationDiagnosticState(
            screen: "workspace",
            identifier: String(identifier.uuidString.prefix(8)),
            showsGrid: showsGrid,
            isNewChatPresentation: isNewChatPresentation,
            hasStarted: hasStarted,
            isDraft: isDraft,
            blocksServerContent: blocksServerContent,
            expectsNativeBack: !isNewChatPresentation && !showsGrid,
            expectsLeadingButton: (showsGrid && !isNewChatPresentation)
                || (isNewChatPresentation
                    && (hasStarted || isFirstSendPromotionSurface)),
            expectsTrailingButton: (isNewChatPresentation && !hasStarted)
                || (!blocksServerContent && !isDraft),
            contentPhase: contentPhase
        )
    }

    private func diagnosticID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// The draft's first surface when its machine has no usable project.
    /// This is the real file picker, hosted by the sheet's navigation stack.
    private var initialProjectPicker: some View {
        RemoteDirectoryScreen(directory: .home) { path in
            addInitialProject(at: path)
        }
        .navigationTitle("New Project")
    }

    private var baseTitle: String {
        // An unsent draft says what it is; the moment it becomes a real chat the
        // title clears like any other chat pane, so the nav bar doesn't change
        // shape under the send.
        if isDraft { return hasStarted ? "" : "New Chat" }
        if showsGrid {
            return "\(panes.panes.count) Tab\(panes.panes.count == 1 ? "" : "s")"
        }
        guard let pane = activePane else { return "" }
        // Chat panes hide the title so the transcript scrolls off the top.
        return pane.kind == .chat ? "" : title(for: pane)
    }

    // MARK: - Tab grid (the workspace's base)

    /// The Safari-style tab switcher: a two-column grid of pane previews with
    /// close buttons.
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(panes.panes) { pane in
                        PaneCard(
                            pane: pane,
                            title: title(for: pane),
                            snapshot: paneStorageId.flatMap {
                                PaneSnapshotCache.shared.image(
                                    for: pane.id,
                                    in: $0
                                )
                            },
                            onSelect: {
                                guard gridDrag == nil,
                                      suppressedPaneTapId != pane.id
                                else { return }
                                select(pane)
                            },
                            onClose: { close(pane) },
                            onMoveEarlier: moveAction(for: pane, offset: -1),
                            onMoveLater: moveAction(for: pane, offset: 1)
                        )
                        .id(pane.id)
                        // The grid-owned lifted preview is the only copy that
                        // follows the finger. This fully transparent cell
                        // remains in layout as the insertion gap and moves
                        // with the canonical pane order.
                        .opacity(gridDrag?.pane.id == pane.id ? 0 : 1)
                        // Reordering must coexist with the close Button.
                        // High-priority recognition starved that nested
                        // control before it could receive an ordinary tap.
                        .simultaneousGesture(
                            paneReorderGesture(for: pane)
                        )
                    }
                }
                .padding(16)
            }
            .onChange(of: pendingNewTabZoomPaneId) { _, paneId in
                guard let paneId else { return }
                // A large workspace may append the new card below the lazy
                // grid's viewport. Make its measured card the real zoom
                // source without adding a second, competing scroll motion.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(paneId, anchor: .bottom)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .onPreferenceChange(PaneCardFramePreferenceKey.self) { frames in
            paneCardFrames = frames
            startPendingGridZoomIfPossible()
            startPendingNewTabZoomIfPossible()
        }
        .sensoryFeedback(.selection, trigger: gridLiftFeedback)
        .onChange(of: gridDragGestureIsActive) { wasActive, isActive in
            if wasActive, !isActive {
                finishGridDrag()
            }
        }
        .onChange(of: showsGrid) { _, isShowing in
            if !isShowing {
                gridDrag = nil
                suppressedPaneTapId = nil
            }
        }
        .overlay {
            GeometryReader { proxy in
                gridDragOverlay(in: proxy)
            }
            .allowsHitTesting(false)
        }
    }

    private func paneReorderGesture(
        for pane: PaneDescriptorState
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.18, maximumDistance: 12)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .global
                )
            )
            .updating($gridDragGestureIsActive) { phase, isActive, _ in
                if case .second(true, _) = phase {
                    isActive = true
                }
            }
            .onChanged { phase in
                guard case let .second(true, value) = phase,
                      let value
                else { return }
                updateGridDrag(for: pane, value: value)
            }
    }

    private func updateGridDrag(
        for pane: PaneDescriptorState,
        value: DragGesture.Value
    ) {
        if gridDrag == nil {
            guard
                let frame = paneCardFrames[pane.id],
                let currentSlotIndex = panes.panes.firstIndex(where: {
                    $0.id == pane.id
                })
            else { return }
            let slots = panes.panes.enumerated().compactMap { index, pane in
                paneCardFrames[pane.id].map {
                    WorkspaceTabGridSlot(index: index, frame: $0)
                }
            }
            let snapshot = paneStorageId.flatMap {
                PaneSnapshotCache.shared.image(for: pane.id, in: $0)
            }
            gridDrag = WorkspaceTabGridDragState(
                pane: pane,
                title: title(for: pane),
                snapshot: snapshot,
                size: frame.size,
                grabOffset: CGSize(
                    width: min(max(value.startLocation.x - frame.minX, 0), frame.width),
                    height: min(max(value.startLocation.y - frame.minY, 0), frame.height)
                ),
                slots: slots,
                currentSlotIndex: currentSlotIndex,
                fingerLocation: value.location,
                liftProgress: 0
            )
            suppressedPaneTapId = pane.id
            gridLiftFeedback += 1

            Task { @MainActor in
                await Task.yield()
                guard var drag = gridDrag, drag.pane.id == pane.id else { return }
                drag.liftProgress = 1
                withAnimation(WorkspaceTabGridMotion.lift) {
                    gridDrag = drag
                }
            }
        }

        guard var drag = gridDrag, drag.pane.id == pane.id else { return }
        drag.fingerLocation = value.location
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridDrag = drag
        }

        let liftedCenter = CGPoint(
            x: value.location.x - drag.grabOffset.width + drag.size.width / 2,
            y: value.location.y - drag.grabOffset.height + drag.size.height / 2
        )
        reorderDraggedPane(pane.id, nearestTo: liftedCenter)
    }

    private func reorderDraggedPane(_ paneId: UUID, nearestTo point: CGPoint) {
        guard var drag = gridDrag, drag.pane.id == paneId,
              let targetIndex = WorkspaceTabGridReorderContract.targetIndex(
                  currentIndex: drag.currentSlotIndex,
                  point: point,
                  slots: drag.slots
              ),
              panes.panes.indices.contains(targetIndex),
              panes.panes[targetIndex].id != paneId
        else { return }

        let targetPaneId = panes.panes[targetIndex].id
        drag.currentSlotIndex = targetIndex
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridDrag = drag
        }
        reorderPane(paneId, onto: targetPaneId)
    }

    /// Springs the still-opaque lifted tile onto the current empty slot. Only
    /// once both occupy identical geometry do we remove the overlay and
    /// reveal the real card beneath it.
    private func finishGridDrag() {
        guard let paneId = gridDrag?.pane.id else { return }
        Task { @MainActor in
            await Task.yield()
            guard var drag = gridDrag, drag.pane.id == paneId else { return }
            guard let target = drag.slots.first(where: {
                $0.index == drag.currentSlotIndex
            })?.frame else {
                clearGridDrag(paneId: paneId)
                return
            }

            drag.fingerLocation = CGPoint(
                x: target.minX + drag.grabOffset.width,
                y: target.minY + drag.grabOffset.height
            )
            drag.liftProgress = 0
            withAnimation(WorkspaceTabGridMotion.release) {
                gridDrag = drag
            }
            try? await Task.sleep(for: .milliseconds(340))
            clearGridDrag(paneId: paneId)
        }
    }

    private func clearGridDrag(paneId: UUID) {
        guard gridDrag?.pane.id == paneId else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gridDrag = nil
        }
        Task { @MainActor in
            await Task.yield()
            if suppressedPaneTapId == paneId {
                suppressedPaneTapId = nil
            }
        }
    }

    @ViewBuilder
    private func gridDragOverlay(in proxy: GeometryProxy) -> some View {
        if let drag = gridDrag {
            let containerFrame = proxy.frame(in: .global)
            let origin = CGPoint(
                x: drag.fingerLocation.x - drag.grabOffset.width - containerFrame.minX,
                y: drag.fingerLocation.y - drag.grabOffset.height - containerFrame.minY
            )
            PanePreviewTile(
                pane: drag.pane,
                snapshot: drag.snapshot,
                title: drag.title,
                showsCloseButton: false,
                onClose: {}
            )
            .frame(width: drag.size.width, height: drag.size.height)
            .scaleEffect(1 + 0.045 * drag.liftProgress)
            .shadow(
                color: Color.black.opacity(0.22 * drag.liftProgress),
                radius: 12 * drag.liftProgress,
                x: 0,
                y: 6 * drag.liftProgress
            )
            .position(
                x: origin.x + drag.size.width / 2,
                y: origin.y + drag.size.height / 2
            )
            .accessibilityHidden(true)
        }
    }

    private var paneBinding: Binding<PaneGroupState> {
        Binding(
            get: { panes },
            set: { newValue in
                var state = newValue
                // macOS behavior: a group never goes empty — closing the last
                // pane leaves a New Tab page in its place.
                if state.panes.isEmpty {
                    state.addNewTabPane()
                }
                paneState = state
                if let paneStorageId {
                    WorkspacePaneStore.shared.save(state, for: paneStorageId)
                }
            }
        )
    }

    @ViewBuilder
    private func paneContent(_ pane: PaneDescriptorState) -> some View {
        switch pane.kind {
        case .chat:
            // Resolved via the cache (and the draft controller) so an
            // already-live chat renders on the FIRST frame — a just-sent
            // message must never flash a spinner over itself.
            if let controller = chatController(for: pane) {
                SessionTranscriptView(
                    controller: controller,
                    // A draft picks where it will run; sending fixes that, so
                    // the chips animate away in place.
                    showsRunPickers: isDraft && !hasStarted,
                    initialComposerFocusRequest: initialComposerFocusRequest,
                    onInitialComposerFocusRequestFulfilled:
                        onInitialComposerFocusRequestFulfilled,
                    presentationRole: transcriptPresentationRole,
                    onSendAnimationCompleted: onSendAnimationCompleted,
                    onSendAnimationStarted: onSendAnimationStarted,
                    onComposerWillSend: onComposerWillSend,
                    preservesComposerFocusOnSend: isNewChatPresentation
                        && !isFirstSendPromotionSurface,
                    composerTextEditorHandoffRole: composerTextEditorHandoffRole,
                    composerTextEditorHandoffID: composerTextEditorHandoffID
                )
                .onAppear {
                    guard let chatId = pane.chatSessionId ?? activeSessionId,
                          let session = session(for: chatId) else { return }
                    if !isNewChatPresentation {
                        onWorkspaceReady?(chatId)
                    }
                    guard transcriptPresentationRole == .foreground else { return }
                    // Attention: only the visible chat is open. A workspace
                    // prewarmed beneath New Chat must not mutate read state.
                    ChatControllerCache.shared.noteOpened(
                        sessionId: chatId,
                        serverId: session.serverId,
                        projectList: environment.projectList
                    )
                    controller.rememberCurrentComposerConfiguration()
                }
                .onChange(of: transcriptPresentationRole) { _, role in
                    guard role == .foreground,
                          let chatId = pane.chatSessionId ?? activeSessionId,
                          let session = session(for: chatId) else { return }
                    ChatControllerCache.shared.noteOpened(
                        sessionId: chatId,
                        serverId: session.serverId,
                        projectList: environment.projectList
                    )
                    controller.rememberCurrentComposerConfiguration()
                }
                .onDisappear {
                    guard let chatId = pane.chatSessionId ?? activeSessionId,
                          let session = session(for: chatId) else { return }
                    // During promotion the same cached controller is already
                    // open in the mounted parent destination. Removing the
                    // sheet must not clear that destination's open marker.
                    guard !(isNewChatPresentation && hasStarted) else { return }
                    guard transcriptPresentationRole == .foreground else { return }
                    ChatControllerCache.shared.noteClosed(
                        sessionId: chatId,
                        serverId: session.serverId
                    )
                }
            } else if let chatId = pane.chatSessionId ?? activeSessionId {
                DelayedWorkspaceLoadingView()
                    .task { await connectChat(sessionId: chatId) }
            } else {
                DelayedWorkspaceLoadingView()
            }
        case .newTab:
            NewTabPaneView(
                projectName: resolvedProject?.name ?? "",
                onNewChat: { convertToChat(pane) },
                onNewTerminal: { convertToTerminal(pane) }
            )
        case .terminal:
            if let serverConfig {
                TerminalPaneView(
                    terminalKey: pane.terminalKey,
                    cwd: workspaceCwd,
                    config: serverConfig
                )
            } else {
                ContentUnavailableView("No Machine", systemImage: "bolt.slash")
            }
        }
    }

    // MARK: - Tab actions

    private func select(_ pane: PaneDescriptorState) {
        openPaneFromGrid(pane)
    }

    private func openPaneFromGrid(_ pane: PaneDescriptorState) {
        let bottomChrome = pane.kind == .chat
            ? PaneSnapshotCache.shared.activeBottomChrome
            : 0
        guard showsGrid,
              tabZoomSurface == nil,
              let paneStorageId,
              let cardFrame = paneCardFrames[pane.id],
              let storedSnapshot = PaneSnapshotCache.shared.transitionSnapshot(
                  for: pane.id,
                  in: paneStorageId,
                  bottomChrome: bottomChrome
              )
        else {
            selectPaneWithoutZoom(pane)
            return
        }

        let paneSnapshot: PaneTransitionSnapshot
        let isUncached: Bool
        if storedSnapshot.image != nil {
            paneSnapshot = storedSnapshot
            isUncached = false
        } else if let fallback = renderPaneCanvas(
            for: pane,
            size: storedSnapshot.contentFrame.size,
            sourceCardFrame: cardFrame
        ) {
            // This image exists only to carry an unvisited card through the
            // exact same zoom. The live pane replaces it at the late handoff;
            // it is never written as if it were a real pane capture.
            paneSnapshot = PaneTransitionSnapshot(
                image: fallback,
                contentFrame: storedSnapshot.contentFrame,
                transitionView: nil,
                backdropView: nil
            )
            isUncached = true
        } else {
            selectPaneWithoutZoom(pane)
            return
        }

        guard
              let surface = WorkspaceTabZoomSurface.make(
                  direction: .gridToPane,
                  paneSnapshot: paneSnapshot,
                  cardFrame: cardFrame,
                  reduceMotion: accessibilityReduceMotion,
                  handoffDelayFactor: isUncached
                      ? WorkspaceTabZoomTransitionContract.uncachedHandoffDelayFactor
                      : WorkspaceTabZoomTransitionContract.handoffDelayFactor
              )
        else {
            selectPaneWithoutZoom(pane)
            return
        }

        surface.install()
        tabZoomSurface = surface
        selectPaneWithoutZoom(pane)
        Task { @MainActor in
            // Commit the canonical pane before revealing it beneath the
            // expanding card. No second workspace or presentation is made.
            await Task.yield()
            surface.animate {
                if tabZoomSurface === surface { tabZoomSurface = nil }
            }
        }
    }

    private func selectPaneWithoutZoom(_ pane: PaneDescriptorState) {
        var state = panes
        state.selectedPaneId = pane.id
        paneBinding.wrappedValue = state
        setShowsGridWithoutAnimation(false)
    }

    /// Any tab can close — chats included, as on macOS. The binding's setter
    /// backfills a New Tab page if the last one goes.
    private func close(_ pane: PaneDescriptorState) {
        var state = panes
        guard state.closePane(id: pane.id) != nil else { return }
        withAnimation(WorkspaceTabGridMotion.removal) {
            paneBinding.wrappedValue = state
        }
        if let paneStorageId {
            PaneSnapshotCache.shared.remove(
                paneId: pane.id,
                from: paneStorageId
            )
        }
    }

    /// The canonical pane array is also the persisted order. Updating it at
    /// each crossed card gives the drag live Safari-style displacement and
    /// makes the latest order crash-safe without a second transient model.
    private func reorderPane(_ paneId: UUID, onto targetPaneId: UUID) {
        var state = panes
        let previousOrder = state.panes.map(\.id)
        state.movePane(id: paneId, onto: targetPaneId)
        guard state.panes.map(\.id) != previousOrder else { return }
        withAnimation(WorkspaceTabGridMotion.reorder) {
            paneBinding.wrappedValue = state
        }
    }

    /// VoiceOver exposes the same persistent reorder without requiring the
    /// spatial drag gesture.
    private func moveAction(
        for pane: PaneDescriptorState,
        offset: Int
    ) -> (() -> Void)? {
        guard let index = panes.panes.firstIndex(where: { $0.id == pane.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard panes.panes.indices.contains(targetIndex) else { return nil }
        let targetId = panes.panes[targetIndex].id
        return { reorderPane(pane.id, onto: targetId) }
    }

    /// Add the placeholder to the real grid first, then expand that exact
    /// card into its page like Safari. This remains the same pane and the same
    /// WorkspaceScreen throughout; only temporary pixels bridge the two
    /// canonical layout states.
    private func addTab() {
        if let sourcePane = activePane ?? panes.panes.first {
            chatController(for: sourcePane)?.rememberCurrentComposerConfiguration()
        }
        var state = panes
        let newPane = state.addNewTabPane()
        paneBinding.wrappedValue = state

        guard showsGrid, !accessibilityReduceMotion else {
            setShowsGridWithoutAnimation(false)
            return
        }

        pendingNewTabZoomPaneId = newPane.id
        Task { @MainActor in
            // Preference delivery normally starts the transition on the next
            // layout pass. Never leave input disabled if a lazy-grid card
            // cannot be measured for an exceptional layout.
            try? await Task.sleep(for: .milliseconds(350))
            guard pendingNewTabZoomPaneId == newPane.id else { return }
            pendingNewTabZoomPaneId = nil
            setShowsGridWithoutAnimation(false)
        }
    }

    /// The grid's back button returns to the workspace's last-open tab.
    private func reopenSelectedPane() {
        guard let activePane else { return }
        openPaneFromGrid(activePane)
    }

    /// Snapshot the pane for its card, then reveal the workspace-local grid.
    private func showGrid(from pane: PaneDescriptorState) {
        guard let paneStorageId else {
            showsGrid = true
            return
        }
        let paneSnapshot = PaneSnapshotCache.shared.captureKeyWindow(
            for: pane.id,
            in: paneStorageId,
            bottomChrome: pane.kind == .chat ? PaneSnapshotCache.shared.activeBottomChrome : 0
        )
        guard tabZoomSurface == nil,
              !accessibilityReduceMotion,
              let paneSnapshot,
              let surface = WorkspaceTabZoomSurface.make(
                  direction: .paneToGrid,
                  paneSnapshot: paneSnapshot,
                  // The grid has not mounted yet. A non-empty provisional
                  // card is replaced by its measured frame before animation.
                  cardFrame: CGRect(
                      x: 16,
                      y: paneSnapshot.contentFrame.minY,
                      width: 1,
                      height: 1
                  ),
                  reduceMotion: false
              )
        else {
            showsGrid = true
            return
        }

        surface.install()
        tabZoomSurface = surface
        pendingGridZoomPaneId = pane.id
        setShowsGridWithoutAnimation(true)

        Task { @MainActor in
            await Task.yield()
            startPendingGridZoomIfPossible()
            try? await Task.sleep(for: .milliseconds(250))
            guard pendingGridZoomPaneId == pane.id,
                  tabZoomSurface === surface
            else { return }
            // A card can be absent when a large lazy grid has it offscreen.
            // Never strand a frozen overlay waiting for impossible geometry.
            pendingGridZoomPaneId = nil
            surface.cancel()
            if tabZoomSurface === surface { tabZoomSurface = nil }
        }
    }

    private func startPendingGridZoomIfPossible() {
        guard let paneId = pendingGridZoomPaneId,
              let frame = paneCardFrames[paneId],
              let surface = tabZoomSurface
        else { return }

        // The full-screen source snapshot was captured before the grid
        // existed. Retarget that SAME snapshot once the real destination card
        // has a frame; recapturing here would incorrectly photograph the grid.
        guard surface.retarget(
            cardFrame: frame,
            reduceMotion: accessibilityReduceMotion
        ) else {
            pendingGridZoomPaneId = nil
            surface.cancel()
            tabZoomSurface = nil
            return
        }
        pendingGridZoomPaneId = nil
        surface.animate {
            if tabZoomSurface === surface { tabZoomSurface = nil }
        }
    }

    /// A brand-new pane has no historical screenshot yet. Render the actual
    /// NewTabPaneView at the pane's fixed canvas size, then feed those pixels
    /// into the same grid-to-pane surface used by every existing tab. The
    /// live grid supplies the backdrop and the live new pane is committed
    /// underneath it before the expansion begins.
    private func startPendingNewTabZoomIfPossible() {
        guard let paneId = pendingNewTabZoomPaneId,
              tabZoomSurface == nil,
              showsGrid,
              let paneStorageId,
              let pane = panes.panes.first(where: {
                  $0.id == paneId && $0.kind == .newTab
              }),
              let cardFrame = paneCardFrames[paneId],
              let geometry = PaneSnapshotCache.shared.transitionSnapshot(
                  for: paneId,
                  in: paneStorageId
              ),
              let paneImage = renderPaneCanvas(
                  for: pane,
                  size: geometry.contentFrame.size,
                  sourceCardFrame: cardFrame
              )
        else { return }

        PaneSnapshotCache.shared.store(
            paneImage,
            for: paneId,
            in: paneStorageId
        )
        let paneSnapshot = PaneTransitionSnapshot(
            image: paneImage,
            contentFrame: geometry.contentFrame,
            transitionView: nil,
            // `make` snapshots the still-live grid before canonical pane
            // selection changes, preserving the inserted card underneath.
            backdropView: nil
        )
        guard let surface = WorkspaceTabZoomSurface.make(
            direction: .gridToPane,
            paneSnapshot: paneSnapshot,
            cardFrame: cardFrame,
            reduceMotion: accessibilityReduceMotion
        ) else {
            pendingNewTabZoomPaneId = nil
            setShowsGridWithoutAnimation(false)
            return
        }

        surface.install()
        tabZoomSurface = surface
        pendingNewTabZoomPaneId = nil
        selectPaneWithoutZoom(pane)
        Task { @MainActor in
            await Task.yield()
            surface.animate {
                if tabZoomSurface === surface { tabZoomSurface = nil }
            }
        }
    }

    private func renderPaneCanvas(
        for pane: PaneDescriptorState,
        size: CGSize,
        sourceCardFrame: CGRect
    ) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let content: AnyView
        if pane.kind == .newTab {
            content = AnyView(
                NewTabPaneView(
                    projectName: resolvedProject?.name ?? "",
                    onNewChat: {},
                    onNewTerminal: {}
                )
                .frame(width: size.width, height: size.height)
            )
        } else {
            content = AnyView(
                UncachedPanePreviewView(
                    kind: pane.kind,
                    canvasSize: size,
                    sourceCardSize: sourceCardFrame.size
                )
            )
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = min(2, displayScale)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private func setShowsGridWithoutAnimation(_ value: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showsGrid = value }
    }

    /// The macOS new-tab conversion: the placeholder becomes a real pane in
    /// place. Chats are created eagerly as deferred sessions (the agent
    /// spawns on first send), exactly like the New Workspace flow. New chats
    /// inherit the workspace's one working directory: the root session's
    /// worktree (or project folder) stamps every sub-chat at creation.
    private func convertToChat(_ pane: PaneDescriptorState) {
        // Reachable only from the tab grid, which a draft doesn't have.
        guard let project = resolvedProject, let workspaceSessionId = activeSessionId else { return }
        let chat = environment.projectList.newSession(
            in: project,
            title: "New Chat",
            worktreeName: rootSession?.worktreeName,
            cwd: rootSession?.cwd
        )
        var state = panes
        state.convertNewTabPane(
            id: pane.id, to: .chat, sessionId: workspaceSessionId, chatSessionId: chat.id
        )
        paneBinding.wrappedValue = state
        registerChatInWorkspace(chat)
    }

    private func convertToTerminal(_ pane: PaneDescriptorState) {
        guard let workspaceSessionId = activeSessionId else { return }
        var state = panes
        state.convertNewTabPane(id: pane.id, to: .terminal, sessionId: workspaceSessionId)
        paneBinding.wrappedValue = state
    }

    /// Keep the shared workspace's chat index in lockstep with iOS's compact
    /// tab state. Home reads this index to build the same workspace → chats
    /// hierarchy as macOS.
    private func registerChatInWorkspace(_ chat: ChatSession) {
        guard var workspace = resolvedWorkspace else { return }
        if workspace.tabId(containingChat: chat.id) == nil {
            let tab = WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))
            workspace.centerTabs.append(tab)
            workspace.selectedCenterTabId = tab.id
        }
        environment.workspaces.save(workspace)
    }

    // MARK: - Connection

    private func prepare() async {
        IOSNavigationDiagnostics.record(
            "workspace.prepare.begin",
            "session=\(activeSessionId.map(diagnosticID) ?? "nil") controllers=\(controllers.count)"
        )
        guard let sessionId = activeSessionId else {
            // Stale while revalidate, matching macOS New Chat: construct from
            // the persisted project snapshot before the first suspension, then
            // refresh metadata without holding the sheet behind a spinner.
            setUpDraftIfNeeded()
            await environment.projectList.refreshFromServer()
            setUpDraftIfNeeded()
            IOSNavigationDiagnostics.record("workspace.prepare.end", "draft=true")
            return
        }
        if paneState == nil, let paneStorageId {
            var state = WorkspacePaneStore.shared.state(
                for: paneStorageId,
                legacySessionIds: legacyPaneSessionIds
            )
            if let preferredChatSessionId {
                if let pane = state.panes.first(where: {
                    $0.kind == .chat && $0.chatSessionId == preferredChatSessionId
                }) {
                    state.selectPane(id: pane.id)
                } else {
                    _ = state.addChatPane(sessionId: preferredChatSessionId)
                }
                WorkspacePaneStore.shared.save(state, for: paneStorageId)
            }
            paneState = state
        }
        if controllers[sessionId] == nil {
            guard let session = rootSession,
                  let project = environment.projectList.projects.first(where: {
                      $0.serverId == session.serverId && $0.id == session.projectId
                  })
            else {
                missing = true
                IOSNavigationDiagnostics.record(
                    "workspace.prepare.abort",
                    "session=\(diagnosticID(sessionId)) reason=session-or-project-missing"
                )
                return
            }
            self.project = project
            serverConfig = environment.machines.serverConfig(for: session.serverId)
        }
        await connectChat(sessionId: sessionId)
        IOSNavigationDiagnostics.record(
            "workspace.prepare.end",
            "session=\(diagnosticID(sessionId)) controllers=\(controllers.count)"
        )
    }

    // MARK: - The draft (a new chat, before its first send)

    /// Binds the app-wide retained draft controller and wires what its first
    /// send should do. Idempotent: re-runs harmlessly as the project list
    /// arrives.
    private func setUpDraftIfNeeded(preferredProject: Project? = nil) {
        guard isDraft, draftController == nil else { return }
        guard let project = preferredProject ?? draftProjectCandidate
        else { return }
        // The retained draft: leaving and coming back — or relaunching —
        // restores the unsent message, attachments, and picked run location.
        let controller = ChatControllerCache.shared.draftController(
            preferredProject: project,
            environment: environment
        )
        serverConfig = environment.machines.serverConfig(for: controller.project.serverId)
        // Pin the draft's pane group NOW: `centerInitial` mints a fresh pane id
        // each call, so leaving it computed would hand the chat view a new
        // identity every render — remounting it constantly.
        if paneState == nil {
            paneState = PaneGroupState.centerInitial(sessionId: draftPlaceholderId)
        }
        controller.onFirstSend = { [weak controller] in
            guard let controller else { return }
            adoptSession(for: controller)
        }
        draftController = controller
        Task { await controller.prepare() }
    }

    private func addInitialProject(at path: String) {
        let addedProject = environment.projectList.addProject(
            folderURL: URL(fileURLWithPath: path)
        )
        project = addedProject
        setUpDraftIfNeeded(preferredProject: addedProject)

        // A folder may have been selected several pushes deep. Reveal this
        // same draft destination without replacing it.
        onInitialProjectAdded?()
    }

    /// The draft's first send: create the session and become its workspace,
    /// in place. The pane keeps its id and the transcript keeps its controller,
    /// so the chat view is never rebuilt — the run pickers simply collapse and
    /// the sent message rides its lift up into the history.
    private func adoptSession(for controller: SessionController) {
        guard let project = resolvedProject else { return }
        let session = environment.projectList.newSession(
            in: project,
            // `send()` clears the durable draft before this callback so every
            // destination composer mounts empty. The optimistic row is the
            // authoritative snapshot of the outgoing prompt at this point.
            title: Self.chatTitle(
                from: controller.pendingUserMessage?.text ?? controller.composerText
            ),
            harnessId: controller.selectedHarnessId,
            worktreeName: controller.worktreeName,
            cwd: controller.sessionCwdOverride,
            syncToServer: false
        )
        controller.serverSession = session
        controller.onWorktreeCreated = { [weak projectList = environment.projectList] worktree in
            projectList?.setWorktree(
                name: worktree.name,
                cwd: worktree.path,
                for: session.id,
                serverId: session.serverId
            )
        }
        ChatControllerCache.shared.register(
            controller,
            for: session,
            environment: environment
        )
        let workspace = environment.workspaces.ensureWorkspace(
            for: WorkspaceSessionSeed(
                sessionId: session.id,
                initialName: session.worktreeName ?? project.name,
                serverId: session.serverId,
                projectId: project.id,
                rootDirectory: session.cwd ?? project.folderURL.path,
                worktreeName: session.worktreeName
            ),
            legacyGroups: environment.paneGroups
        )
        environment.composerDefaults.performPersistenceBatch(flushImmediately: true) {
            environment.composerDefaults.rememberNewWorkspaceProject(
                serverId: project.serverId,
                projectId: project.id
            )
            environment.composerDefaults.rememberNewWorkspaceWorktreePreference(
                serverId: project.serverId,
                createsWorktree: controller.wantsNewWorktree
            )
            controller.rememberCurrentComposerConfiguration()
            controller.moveComposerDefaults(
                to: .workspace(id: workspace.id, serverId: session.serverId)
            )
        }
        // Save the draft pane under the real session before Home mounts the
        // normal workspace route. Both containers resolve the same cached
        // controller and pane identity during the covered handoff.
        var state = panes
        if let index = state.panes.firstIndex(where: { $0.kind == .chat }) {
            state.panes[index].chatSessionId = session.id
        }
        WorkspacePaneStore.shared.save(state, for: workspace.id)
        if isNewChatPresentation {
            // Keep the source draft hierarchy mounted until Home has moved
            // first-responder ownership into the independent promotion
            // window. Adopting the session in this sheet remounted its
            // composer immediately, which dismissed the keyboard hundreds of
            // milliseconds before the overlay editor existed.
            onDraftStarted?(session.id)
            return
        }
        controllers[session.id] = controller
        self.project = project
        startedSessionId = session.id
        paneState = state
        withAnimation(
            .timingCurve(
                0.22,
                1,
                0.36,
                1,
                duration: TranscriptSendAnimationMetrics.duration
            )
        ) {
            hasStarted = true
        }
        // Mount the genuine workspace route in the same send turn. The
        // covering surface and the optimistic row now start together instead
        // of waiting for the request to leave the composer.
        onDraftStarted?(session.id)
    }

    private func dismissNewChatPresentation() {
        if let onDismissNewChat {
            onDismissNewChat()
        } else {
            dismiss()
        }
    }

    private static func chatTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(separator: "\n").first.map(String.init) ?? "New session"
        return firstLine.count > 48
            ? String(firstLine.prefix(48)) + "…"
            : (firstLine.isEmpty ? "New session" : firstLine)
    }

    private func connectChat(sessionId chatId: UUID) async {
        IOSNavigationDiagnostics.record(
            "workspace.connectChat.begin",
            "session=\(diagnosticID(chatId)) localController=\(controllers[chatId] != nil)"
        )
        guard controllers[chatId] == nil else {
            IOSNavigationDiagnostics.record(
                "workspace.connectChat.skip",
                "session=\(diagnosticID(chatId)) reason=local-controller-present"
            )
            return
        }
        guard let session = session(for: chatId) else {
            IOSNavigationDiagnostics.record(
                "workspace.connectChat.skip",
                "session=\(diagnosticID(chatId)) reason=session-missing"
            )
            return
        }
        guard let project = environment.projectList.projects.first(where: {
            $0.serverId == session.serverId && $0.id == session.projectId
        })
        else {
            IOSNavigationDiagnostics.record(
                "workspace.connectChat.skip",
                "session=\(diagnosticID(chatId)) reason=project-missing"
            )
            return
        }
        // App-wide cache: revisiting a chat rebinds the SAME controller, so a
        // stream that kept flowing while we were away renders immediately.
        let controller = ChatControllerCache.shared.controller(
            for: session,
            project: project,
            workspaceId: resolvedWorkspace?.id ?? activeSessionId ?? chatId,
            environment: environment
        )
        controllers[chatId] = controller
        IOSNavigationDiagnostics.record(
            "workspace.connectChat.controller",
            "session=\(diagnosticID(chatId)) model=\(controller.model != nil) connecting=\(controller.isConnecting) historyLoading=\(controller.isLoadingInitialHistory)"
        )
        guard controller.model == nil, !controller.isConnecting else {
            IOSNavigationDiagnostics.record(
                "workspace.connectChat.skip",
                "session=\(diagnosticID(chatId)) reason=\(controller.model != nil ? "model-present" : "already-connecting")"
            )
            return
        }
        if session.agentSessionId?.isEmpty != false {
            // A fresh chat: no agent exists yet. Load harness capabilities so
            // the composer validates; the agent spawns on the first send.
            await controller.prepare()
            controller.applyComposerDefaults()
        }
        IOSNavigationDiagnostics.record("workspace.connectChat.connect.begin", "session=\(diagnosticID(chatId))")
        await controller.connectIfNeeded()
        IOSNavigationDiagnostics.record(
            "workspace.connectChat.connect.end",
            "session=\(diagnosticID(chatId)) model=\(controller.model != nil) connecting=\(controller.isConnecting) historyLoading=\(controller.isLoadingInitialHistory)"
        )
    }

}

/// Navigation and chrome mount without an indeterminate flash. If controller
/// or workspace preparation exceeds the grace period, the wait becomes
/// explicit while the async destination task continues.
private struct DelayedWorkspaceLoadingView: View {
    @State private var showsSpinner = false

    var body: some View {
        ZStack {
            Color.clear
            if showsSpinner {
                ProgressView()
                    .accessibilityLabel("Loading conversation")
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showsSpinner = true
        }
    }
}

/// Keeps the draft-only file-browser route out of Home's typed navigation
/// stack. The new-chat sheet uses a type-erased NavigationPath and owns this
/// destination at its root; regular workspaces must never register it.
private struct InitialProjectNavigationDestination: ViewModifier {
    let isEnabled: Bool
    let onPick: (String) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.navigationDestination(for: RemoteDirectory.self) { directory in
                RemoteDirectoryScreen(directory: directory, onPick: onPick)
            }
        } else {
            content
        }
    }
}

// MARK: - New tab page

/// The iOS take on macOS's new-tab page: pick what this tab becomes. The
/// placeholder converts in place, so the tab keeps its slot in the grid.
private struct NewTabPaneView: View {
    let projectName: String
    let onNewChat: () -> Void
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            newTabOption(
                title: "New Chat",
                subtitle: "Start an agent in \(projectName)",
                systemImage: "bubble.left.and.bubble.right",
                action: onNewChat
            )
            newTabOption(
                title: "New Terminal",
                subtitle: "Open a shell on the machine",
                systemImage: "terminal",
                action: onNewTerminal
            )
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func newTabOption(
        title: String,
        subtitle: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .scaledFrame(width: 34, relativeTo: .title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

/// A fixed-canvas bridge for a pane that has never produced a real preview.
/// Its symbol is positioned so the card endpoint exactly matches the grid's
/// centered placeholder. The canvas then expands uniformly—without a blank
/// frame or instant state change—and dissolves into live UI only at the full
/// pane endpoint.
private struct UncachedPanePreviewView: View {
    let kind: PaneKind
    let canvasSize: CGSize
    let sourceCardSize: CGSize

    private var symbolName: String {
        switch kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        }
    }

    private var background: Color {
        kind == .terminal ? .black : Color(.secondarySystemGroupedBackground)
    }

    private var symbolColor: Color {
        kind == .terminal ? .white.opacity(0.6) : .secondary
    }

    private var symbolCenterY: CGFloat {
        WorkspaceTabZoomTransitionContract.uncachedPlaceholderSymbolCenterY(
            canvasSize: canvasSize,
            cardSize: sourceCardSize
        ) ?? canvasSize.height / 2
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            Image(systemName: symbolName)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(symbolColor)
                .position(x: canvasSize.width / 2, y: symbolCenterY)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }
}

/// The reusable preview rectangle. The grid card and native drag preview use
/// this exact surface and size; drag simply omits the close control.
private struct PanePreviewTile: View {
    let pane: PaneDescriptorState
    let snapshot: UIImage?
    let title: String
    let showsCloseButton: Bool
    let onClose: () -> Void

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    pane.kind == .terminal
                        ? Color.black
                        : Color(.secondarySystemGroupedBackground)
                )
            if let snapshot {
                // Top-aligned fill inside the fixed card, overflow clipped
                // by the card shape.
                Color.clear
                    .overlay(alignment: .top) {
                        Image(uiImage: snapshot)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                VStack {
                    Spacer()
                    Image(systemName: symbolName)
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(
                            pane.kind == .terminal
                                ? Color.white.opacity(0.6)
                                : Color.secondary
                        )
                    Spacer()
                }
            }
        }
        // Fixed Safari-like height: every card matches regardless of how
        // tall its snapshot is.
        .frame(height: 205)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                        .shadow(
                            color: Color.black.opacity(0.16),
                            radius: 3,
                            x: 0,
                            y: 1
                        )
                }
                .buttonStyle(.plain)
                .padding(7)
                .accessibilityLabel("Close \(title)")
            }
        }
    }
}

/// One grid card: reusable preview tile plus its label. The label never
/// participates in the lifted drag preview.
private struct PaneCard: View {
    let pane: PaneDescriptorState
    let title: String
    let snapshot: UIImage?
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMoveEarlier: (() -> Void)?
    let onMoveLater: (() -> Void)?

    private var symbolName: String {
        switch pane.kind {
        case .terminal: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .newTab: "plus.square.on.square"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            PanePreviewTile(
                pane: pane,
                snapshot: snapshot,
                title: title,
                showsCloseButton: true,
                onClose: onClose
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture { onSelect() }
            // The zoom endpoint is the preview itself—not its title row.
            // Matching this exact rectangle keeps the card mask and snapshot
            // aligned at the handoff frame.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaneCardFramePreferenceKey.self,
                        value: [pane.id: proxy.frame(in: .global)]
                    )
                }
            }

            HStack(spacing: 5) {
                Image(systemName: symbolName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Move earlier") {
            onMoveEarlier?()
        }
        .accessibilityAction(named: "Move later") {
            onMoveLater?()
        }
        .transition(
            .scale(scale: 0.84, anchor: .center)
                .combined(with: .opacity)
        )
    }
}
