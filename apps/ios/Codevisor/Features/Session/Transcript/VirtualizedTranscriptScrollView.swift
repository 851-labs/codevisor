import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

/// A UIKit port of the macOS document-view virtualizer. UIScrollView owns only
/// touch tracking and momentum; this view is the single owner of document
/// geometry, row mounting, measurement, restoration, and anchor compensation.
@MainActor
final class VirtualizedTranscriptScrollView: UIScrollView, UIScrollViewDelegate {
    static let rowSpacing: CGFloat = 20
    static let topPadding: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let maxRowWidth: CGFloat = 832
    /// Initial presentation waits for exact geometry across this much content
    /// on both sides of the viewport. The already-mounted runway makes the
    /// first fast swipe consume prepared TextKit/SwiftUI rows rather than
    /// synchronously constructing them under the user's finger.
    static let initialRunwayViewportCount: CGFloat = 1.5
    static let atBottomThreshold: CGFloat = 2
    static let maxParkedHostCount = 16
    static let sendTargetHoldAnimationKey = "codevisor.send-target-hold"
    static let sendAssistantHoldAnimationKey = "codevisor.send-assistant-hold"
    static let sendHistoryHoldAnimationKey = "codevisor.send-history-hold"
    let canvasView = UIView()
    let streamingTextFrameClock = StreamingTextAnimationFrameClock()
    let paginationLoadingIndicator = UIActivityIndicatorView(style: .medium)
    weak var hostingParent: UIViewController?

    /// Row bookkeeping shared with the other platform; see `TranscriptRowSet`.
    var rowSet = TranscriptRowSet()
    var rows: [TranscriptVirtualRow] { rowSet.rows }
    var rowByKey: [String: TranscriptVirtualRow] { rowSet.rowByKey }
    var projectedRows: [TranscriptVirtualRow] {
        get { rowSet.projectedRows }
        set { rowSet.projectedRows = newValue }
    }
    var activeRows: [TranscriptVirtualRow] {
        get { rowSet.activeRows }
        set { rowSet.activeRows = newValue }
    }
    var activeRowsRange: Range<Int>? {
        get { rowSet.activeRowsRange }
        set { rowSet.activeRowsRange = newValue }
    }
    var projectedRowsVersion: TranscriptRowSetRevision?
    /// Received and applied projection revisions differ while UIKit defers a
    /// prepend until an active drag/deceleration ends.
    var receivedProjectionRevision: UInt64?
    var appliedProjectionRevision: UInt64?
    var activeRowsVersion: TranscriptRowSetRevision?
    var virtualLayout = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: rowSpacing,
    )
    var measurements = TranscriptMeasurementLedger()
    var measurementCache = SessionMeasurementCacheStore()
    var layoutFingerprint = 0

    var mountedHosts: [String: TranscriptRowHost] = [:]
    var parkedHosts: [String: TranscriptRowHost] = [:]
    var parkedHostLRU: [String] = []
    let virtualWindowPolicy = TranscriptVirtualWindowPolicy()
    var windowPlanner: TranscriptWindowPlanner {
        TranscriptWindowPlanner(
            policy: virtualWindowPolicy,
            initialRunwayViewportCount: Self.initialRunwayViewportCount
        )
    }
    var virtualWindowHandoff = TranscriptVirtualWindowHandoff()
    var pendingWindowScrollDelta: CGFloat = 0
    var lastObservedContentOffsetY: CGFloat?
    var remainingMountsThisFrame = 2
    var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    var pendingMeasurements: [String: TranscriptRowMeasurement] = [:]
    var measurementCommitTask: Task<Void, Never>?
    weak var sessionController: SessionController?
    var presentationFrameDriverToken: TranscriptFrameDriverToken?
    var presentationDisplayLink: CADisplayLink?
    var displayFrameRequested = false
    var modelPresentationFrameRequested = false
    var mountedRowsUpdateRequested = false
    var measurementCommitGate = TranscriptMeasurementCommitGate()
    var initialPresentationGate = TranscriptInitialPresentationGate()
    var initialBottomPin = TranscriptInitialBottomPin()
    var bottomJumpGate = TranscriptBottomJumpGate()
    var deferredRowsDuringScroll: [TranscriptVirtualRow]?
    var deferredActiveRowsRange: Range<Int>?
    var deferredProjectionRevision: UInt64?

    struct DeferredSendProjection {
        let projectedRows: [TranscriptVirtualRow]
        let projectedRowsVersion: TranscriptRowSetRevision
        let projectionRevision: UInt64
        let activeRows: [TranscriptVirtualRow]
        let activeRowsVersion: TranscriptRowSetRevision
    }

    struct SendHistoryHoldMount {
        let hostID: ObjectIdentifier
        let translationY: CGFloat
    }

    /// The live assistant remains visually hidden during the outgoing flight.
    /// Keep its changing topology out of layout too, then commit only the
    /// latest projection after the flight completes.
    var deferredSendProjection: DeferredSendProjection?

    struct DisclosureViewportAnchor {
        let id: UUID
        let viewportTop: CGFloat
    }

    var disclosureViewportAnchor: DisclosureViewportAnchor?
    var disclosureAnchorReleaseTask: Task<Void, Never>?

    var pendingInitialState: SessionScrollState?
    var lockedRestoreDistance: CGFloat?
    var initialPositionConfigured = false
    var initialPositionApplied = false
    var followsLatest = true
    var hasOlderHistory = false
    var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
    var olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
    var isLoadingInitialHistory = false
    /// Row projection runs off the main actor. A retained session controller can
    /// already own exact scroll geometry while its newly mounted SwiftUI screen
    /// still has a temporary empty row array. Do not consume that geometry or
    /// validate its caches until the first displayable projection arrives
    /// after any initial history hydration.
    var isPreparingInitialProjection = true
    /// The outer row projection initially contains one aggregate `.active` row.
    /// Keep first paint closed until its independently parsed block rows replace
    /// that provisional topology; otherwise an uncached chat visibly jumps from
    /// the aggregate estimate to the final block layout.
    var isActiveProjectionPending = false
    var scrollCommand = TranscriptScrollCommand()
    var receivedSendAnimationToken: UInt64?
    var pendingSendAnimationRequest: UserSendAnimationRequest?
    var pendingSendAnimationRowKey: String?
    var pendingSendSourceLayout: VirtualTranscriptLayout?
    var pendingSendSourceScreenYByRowKey: [String: CGFloat]?
    /// Tracks the host that received each pending history lock. If a bounded
    /// lock expires, later layout passes must not rewind that visible host.
    var sendHistoryHoldMounts: [String: SendHistoryHoldMount] = [:]
    var sendAnimationSourceFrame: CGRect?
    var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    var onSendAnimationStarted:
        (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )?
    var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)?
    var activeSendAnimationRequest: UserSendAnimationRequest?
    var activeSendSourceLayout: VirtualTranscriptLayout?
    /// One bounded assistant hold is allowed per mounted host and send. This
    /// prevents a slow pending projection from re-hiding a row after its
    /// safety hold has deliberately expired.
    var sendAssistantHoldMounts: [String: ObjectIdentifier] = [:]
    var sendPresentationLifecycle = TranscriptSendPresentationLifecycle()
    var sendPresentationWatchdog: Task<Void, Never>?
    var sendAnimationCompletion: TranscriptSendAnimationCompletion?
    var presentationRole: TranscriptPresentationRole = .foreground
    var reduceMotion = false

    var positionApplicationDepth = 0
    var isApplyingPosition: Bool {
        positionApplicationDepth > 0
    }

    var lastDistanceFromBottom: CGFloat = 0
    var lastBottomState: Bool?
    var lastViewportSize: CGSize = .zero
    var historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
    var isDetaching = false
    var isExplicitUserScroll = false
    var lastStableScrollState: SessionScrollState?
    var appliedTopContentInset: CGFloat = 0

    var onViewportChange: ((SessionScrollState) -> Void)?
    var onBottomStateChange: ((Bool) -> Void)?
    var onFollowStateChange: ((Bool) -> Void)?
    var onNearTop: (() -> Bool)?
    var onOlderHistoryPresented: ((UInt64) -> Void)?
    var applicationObserver: NSObjectProtocol?

    var isNativeScrollInteractionActive: Bool {
        isTracking || isDragging || isDecelerating || isExplicitUserScroll
    }
    var maximumMountsPerFrame: Int {
        (window?.screen.maximumFramesPerSecond ?? 60) > 60 ? 2 : 4
    }
    var mountWorkBudget: CFTimeInterval {
        (window?.screen.maximumFramesPerSecond ?? 60) > 60 ? 0.0025 : 0.005
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        streamingTextFrameClock.setFrameRequester { [weak self] in
            self?.requestDisplayFrame()
        }
        delegate = self
        backgroundColor = .clear
        canvasView.backgroundColor = .clear
        addSubview(canvasView)
        paginationLoadingIndicator.color = .secondaryLabel
        paginationLoadingIndicator.hidesWhenStopped = true
        paginationLoadingIndicator.isUserInteractionEnabled = false
        paginationLoadingIndicator.isAccessibilityElement = true
        paginationLoadingIndicator.accessibilityLabel = "Loading older messages"
        canvasView.addSubview(paginationLoadingIndicator)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = true
        indicatorStyle = .default
        automaticallyAdjustsScrollIndicatorInsets = false
        alwaysBounceVertical = true
        alwaysBounceHorizontal = false
        isDirectionalLockEnabled = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
        // Keep estimated row frames out of the first visible paint. The
        // hosted rows still mount and measure normally underneath this canvas.
        canvasView.alpha = 0
        canvasView.accessibilityElementsHidden = true
        isScrollEnabled = false
        applicationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.onMain { [weak self] in self?.interruptSendPresentation() }
        }
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    deinit {
        presentationDisplayLink?.invalidate()
        measurementCommitTask?.cancel()
        disclosureAnchorReleaseTask?.cancel()
        sendPresentationWatchdog?.cancel()
        if let applicationObserver {
            NotificationCenter.default.removeObserver(applicationObserver)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateTopContentInsetIfNeeded()
    }

    override func didMoveToWindow() {
        if window == nil, superview != nil {
            republishLastStableScrollState()
            interruptSendPresentation()
            isDetaching = true
            uninstallPresentationDisplayLink()
        } else if window != nil {
            isDetaching = false
        }
        super.didMoveToWindow()
        if window != nil {
            installPresentationDisplayLink()
        }
    }

    override func layoutSubviews() {
        let previousViewportSize = lastViewportSize
        let previousDistanceFromBottom = lastDistanceFromBottom
        let wasNativeScrollInteractionActive = isNativeScrollInteractionActive
        super.layoutSubviews()
        guard !isDetaching else { return }
        updateTopContentInsetIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else { return }
        guard !isPreparingInitialProjection else { return }

        let hadViewport = previousViewportSize.width > 0 && previousViewportSize.height > 0
        let widthChanged = abs(previousViewportSize.width - bounds.width) > 0.5
        let heightChanged =
            hadViewport
            && abs(previousViewportSize.height - bounds.height) > 0.5
        let resizeAdjustment =
            heightChanged && initialPositionApplied
            ? TranscriptViewportResizeAdjustment.resolve(
                previousDistanceFromBottom: previousDistanceFromBottom,
                atBottomThreshold: Self.atBottomThreshold,
                isUserInteracting: wasNativeScrollInteractionActive
            )
            : nil
        lastViewportSize = bounds.size
        if widthChanged {
            discardParkedHosts()
            _ = activateMeasurementCacheIfNeeded()
            refreshMountedRootViews()
            rebuildDocumentGeometry()
        } else {
            applyPendingInitialPositionIfPossible()
            updateMountedRows()
        }
        if resizeAdjustment == .pinToBottom {
            // SwiftUI keyboard avoidance changes this view's height in the
            // keyboard's own animation transaction. Following every layout
            // step keeps the newest transcript pixels moving with the
            // composer instead of jumping only after the keyboard settles.
            setDistanceFromBottom(0, synchronizesWithActiveLayoutAnimation: true)
            updateMountedRows()
        } else if heightChanged, initialPositionApplied {
            // The raw content offset deliberately stays fixed away from the
            // bottom. Refresh the derived coordinate so a later resize does
            // not mistake the old distance for a bottom-pinned viewport.
            lastDistanceFromBottom = currentDistanceFromBottom()
            publishBottomState(lastDistanceFromBottom <= Self.atBottomThreshold)
        }
        startPendingSendAnimationIfPossible()
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
    }

    // MARK: - Rows and geometry

    var effectiveRowWidth: CGFloat {
        let availableWidth = max(1, bounds.width - Self.horizontalPadding * 2)
        return min(Self.maxRowWidth, availableWidth)
    }

    // MARK: - Viewport

    var viewportHeight: CGFloat {
        max(0, bounds.height)
    }

    var viewportGeometry: VirtualTranscriptViewport {
        VirtualTranscriptViewport(
            contentHeight: paginationHeaderLayout.documentHeight(
                topPadding: Self.topPadding,
                rowsHeight: virtualLayout.totalHeight
            ),
            viewportHeight: viewportHeight,
            topInset: appliedTopContentInset,
        )
    }

    var transcriptRowsOrigin: CGFloat {
        paginationHeaderLayout.rowOrigin(topPadding: Self.topPadding, rowOffset: 0)
    }

    // MARK: - Native scrolling

    // MARK: - Virtual row mounting

    // MARK: - Measurement

    var isActuallyVisible: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return false }
            view = current.superview
        }
        return true
    }

    // MARK: - Disclosure and send presentation

    // MARK: - State and pagination

}
