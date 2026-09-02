import AppKit
import CodevisorCore
import QuartzCore
import StreamMarkdown
import SwiftUI
import CodevisorUI
import TranscriptKit

/// One authoritative owner for viewport position, virtual row mounting, and
/// compensation. It mirrors the architecture of ChatGPT's web scroll
/// controller while retaining AppKit's native gestures, momentum, elasticity,
/// accessibility, and overlay scroller.
@MainActor
final class VirtualizedTranscriptScrollView: NSScrollView {
    static let rowSpacing: CGFloat = 20
    static let topPadding: CGFloat = 28
    static let horizontalPadding: CGFloat = 24
    static let maxRowWidth: CGFloat = 832
    static let initialRunwayViewportCount: CGFloat = 1.5
    static let atBottomThreshold: CGFloat = 2
    static let disclosureExitDuration: CFTimeInterval = 0.2
    static let disclosureExitAnimationKey = "codevisor.disclosure-exit"
    static let disclosureExitMaskAnimationKey = "codevisor.disclosure-exit-mask"
    static let disclosureCollapseAnimationKey = "codevisor.disclosure-collapse"

    struct DisclosureCollapsePresentation {
        let container: TranscriptDisclosureCollapseContainer
        let hosts: [(key: String, host: TranscriptMountedRowHost)]
    }

    let transcriptDocumentView = FlippedTranscriptDocumentView()
    let streamingTextFrameClock = StreamingTextAnimationFrameClock()
    let paginationLoadingIndicator = NSProgressIndicator()
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
    /// Visibility and projection revisions advance independently. Keep the
    /// raw projection revision so disclosure changes cannot be mistaken for a
    /// newly-published settled transcript.
    var receivedProjectionRevision: UInt64?
    var activeRowsVersion: TranscriptRowSetRevision?

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

    var deferredSendProjection: DeferredSendProjection?
    var virtualLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: rowSpacing)
    /// Measured row heights plus staleness. The ledger's invariant is the fix
    /// for settled rows whose content keeps changing (background subagents
    /// streaming into an ended turn): a revision change keeps the old height
    /// as stale layout geometry instead of reverting the row to its estimate.
    var measurements = TranscriptMeasurementLedger()
    var measurementCache = SessionMeasurementCacheStore()
    var layoutFingerprint = 0

    var mountedHosts: [String: TranscriptMountedRowHost] = [:]
    var recycledHosts: [TranscriptRowHost] = []
    /// Detached hosts remain immediately reusable. Hosts exceeding the warm
    /// pool are released one at a time after the gesture.
    var retiringHosts: [TranscriptRowHost] = []
    /// Automatic settlement commits final virtual geometry immediately. One
    /// clipped container retains only the already-mounted worked pixels for the
    /// brief collapse, so disclosure motion never depends on cold measurements.
    var disclosureCollapsePresentations: [UUID: DisclosureCollapsePresentation] = [:]
    var disclosureExitTasks: [UUID: Task<Void, Never>] = [:]
    /// Surviving mounted rows keep their pre-collapse presentation origin for
    /// the same brief interval. Their model frames are already final, but this
    /// interpolation makes the content below travel with the closing body
    /// instead of snapping upward before the outgoing pixels have disappeared.
    var pendingDisclosureCollapseOrigins: [String: CGFloat]?
    let markdownHostCache = TranscriptMarkdownHostCache()
    var recycledMarkdownHosts: [TranscriptMarkdownRowHost] = []
    let virtualWindowPolicy = TranscriptVirtualWindowPolicy()
    var windowPlanner: TranscriptWindowPlanner {
        TranscriptWindowPlanner(
            policy: virtualWindowPolicy,
            initialRunwayViewportCount: Self.initialRunwayViewportCount
        )
    }
    /// The desired pixel runway and the last runway known to be fully laid
    /// out. Keeping both makes a window transition two-phase: prepare the new
    /// runway first, then retire the previous one.
    var virtualWindowHandoff = TranscriptVirtualWindowHandoff()
    var pendingWindowScrollDelta: CGFloat = 0
    var lastObservedViewportTop: CGFloat?
    var runwayMotion = TranscriptRunwayMotion()
    var remainingMountsThisFrame = 2
    var remainingRunwayPreparationsThisFrame = 1
    var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    var openMarkdownLink: (@MainActor (URL) -> Bool)?
    /// One action object for every native Markdown host, forwarding to the
    /// current callback so parked and cached hosts never hold a stale handler.
    lazy var markdownLinkAction = MarkdownLinkAction { [weak self] url in
        self?.openMarkdownLink?(url) ?? false
    }
    var markdownRowStyle = TranscriptMarkdownRowStyle(
        markdown: .default,
        appTheme: .system
    )
    var pendingMeasuredHeights: [String: CGFloat] = [:]
    var measurementCommitTask: Task<Void, Never>?
    weak var sessionController: SessionController?
    var presentationFrameDriverToken: TranscriptFrameDriverToken?
    var presentationDisplayLink: CADisplayLink?
    var displayFrameRequested = false
    var modelPresentationFrameRequested = false
    var mountedRowsUpdateRequested = false
    /// AppKit can synchronously post a clip-view bounds change while a newly
    /// mounted SwiftUI/TextKit row is being laid out. Re-entering reconciliation
    /// from that notification mutates AttributeGraph during its active update.
    /// Keep the visible-row flush synchronous, but coalesce any nested pass onto
    /// a later display/run-loop frame.
    var isUpdatingMountedRows = false
    var deferredMountedRowsUpdateScheduled = false
    var deferredMountedRowsUpdateRequested = false
    var deferredMountedRowsRangeOverride: Range<Int>?
    var initialPresentationGate = TranscriptInitialPresentationGate()
    /// A warm surface keeps displaying its last exact snapshot until both the
    /// newly-created outer and active projection scopes have caught up. This
    /// avoids replacing retained block rows with their provisional aggregate
    /// row during reattachment.
    var isAwaitingWarmProjection = false
    var initialBottomPin = TranscriptInitialBottomPin()
    var bottomJumpGate = TranscriptBottomJumpGate()
    var disclosureViewportAnchor: TranscriptDisclosureViewportAnchor?
    var disclosureAnchorReleaseTask: Task<Void, Never>?

    var pendingInitialState: SessionScrollState?
    /// The saved bottom-distance stays authoritative through initial layout,
    /// reverse pagination, and asynchronous height measurement. It is cleared
    /// only by direct user scrolling or an explicit jump to the latest content.
    var lockedRestoreDistance: CGFloat?
    var initialPositionConfigured = false
    var initialPositionApplied = false
    var followsLatest = true
    var hasOlderHistory = false
    var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
    var isLoadingInitialHistory = false
    var isPreparingInitialProjection = true
    /// The outer row projection initially contains one aggregate `.active` row.
    /// Keep first paint closed until its independently parsed block rows replace
    /// that provisional topology; otherwise an uncached chat visibly jumps from
    /// the aggregate estimate to the final block layout.
    var isActiveProjectionPending = false
    /// The aggregate `.active` placeholder mounted with a clear root while
    /// the surface is still hidden and its precise rows have not published.
    /// Laying out the whole streamed item once as SwiftUI only to discard it a
    /// frame later dominated cold open; the reveal gate already waits for the
    /// first publication, so nothing is ever visible in that window.
    var deferredActivePlaceholderKey: String?
    var isAwaitingFirstActiveProjection = false
    var scrollCommand = TranscriptScrollCommand()
    var receivedSendAnimationToken: UInt64?
    var pendingSendAnimationRequest: UserSendAnimationRequest?
    var pendingSendAnimationRowKey: String?
    /// Layout before the optimistic user row was inserted. It is retained
    /// until the target row has exact geometry, then used only to animate
    /// presentation layers; the scroll position and virtual layout are already
    /// committed at the bottom.
    var pendingSendSourceLayout: VirtualTranscriptLayout?
    var pendingSendSourceViewportYByRowKey: [String: CGFloat]?
    /// Tracks the host that received each pending history lock. If a bounded
    /// lock expires, later layout passes must not rewind that visible host.
    var sendHistoryHoldMounts: [String: SendHistoryHoldMount] = [:]
    var activeSendAnimationRequest: UserSendAnimationRequest?
    var activeSendSourceLayout: VirtualTranscriptLayout?
    /// One bounded assistant hold is allowed per mounted host and send. This
    /// prevents a slow pending projection from re-hiding a row after its
    /// safety hold has deliberately expired.
    var sendAssistantHoldMounts: [String: ObjectIdentifier] = [:]
    var sendPresentationLifecycle = TranscriptSendPresentationLifecycle()
    var sendPresentationWatchdog: Task<Void, Never>?
    var sendAnimationCompletion: TranscriptSendAnimationCompletion?
    var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    var reduceMotion = false
    /// Geometry changes and their compensating scroll are one transaction.
    /// The depth (rather than a Bool) keeps nested position restorations from
    /// briefly looking like user input to the bounds-change observer.
    var positionApplicationDepth = 0
    var isApplyingPosition: Bool { positionApplicationDepth > 0 }
    var isHandlingUserInput = false
    var isLiveScrolling = false
    /// AppKit can deliver the clip-view bounds notification after
    /// `scrollWheel(with:)` returns. Keep a short intent window so that delayed
    /// notification is still classified as user movement, not a system scroll.
    var userInputDeadline: TimeInterval = 0
    var lastDistanceFromBottom: CGFloat = 0
    var lastBottomState: Bool?
    var lastViewportWidth: CGFloat = 0
    var historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
    var isDetaching = false
    /// Last position that was intentionally established by the user, an
    /// initial restore, or an explicit bottom command. AppKit sends bounds
    /// notifications for layout and teardown too; those must never replace it.
    var lastStableScrollState: SessionScrollState?
    var viewportSnapshotGeneration: UInt64 = 0
    var boundsObserver: NSObjectProtocol?
    var liveScrollObservers: [NSObjectProtocol] = []
    var applicationObserver: NSObjectProtocol?

    var onViewportChange: ((SessionScrollState) -> Void)?
    var onBottomStateChange: ((Bool) -> Void)?
    var onFollowStateChange: ((Bool) -> Void)?
    var onNearTop: (() -> Bool)?
    var onInitialPresentationReady: (() -> Void)?
    var isInitialPresentationReady: Bool { initialPresentationGate.isReady }
    var frameBudget: TranscriptFrameBudget {
        TranscriptFrameBudget(
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60,
            isInteracting: isLiveScrolling || isHandlingUserInput
        )
    }
    var maximumMountsPerFrame: Int { frameBudget.mountsPerFrame }
    var mountWorkBudget: CFTimeInterval { frameBudget.workBudget }
    var maximumRunwayPreparationsPerFrame: Int {
        let viewportHeight = max(1, contentView.bounds.height)
        return TranscriptFrameBudget.runwayPreparationsPerFrame(
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond ?? 60,
            projectedDistance: runwayMotion.projectedDelta(
                timestamp: CACurrentMediaTime(),
                maximumDistance: viewportHeight * 3
            ),
            viewportHeight: viewportHeight
        )
    }
    /// The chat history itself can hold keyboard focus: a click anywhere in
    /// it (routed here by TerminalFocusController's mouse monitor) blurs a
    /// focused terminal, the scroll keys in `keyDown(with:)` keep working,
    /// and ordinary typing is handed off to the composer by the same
    /// controller's type-to-focus monitor.
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        streamingTextFrameClock.setFrameRequester { [weak self] in
            self?.requestDisplayFrame()
        }
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        // Focus parks here invisibly (like the Codex/ChatGPT chat history);
        // a ring around the whole transcript would read as a text field.
        focusRingType = .none
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentView.postsBoundsChangedNotifications = true
        transcriptDocumentView.wantsLayer = true
        transcriptDocumentView.layer?.backgroundColor = NSColor.clear.cgColor
        documentView = transcriptDocumentView
        paginationLoadingIndicator.style = .spinning
        paginationLoadingIndicator.controlSize = .small
        paginationLoadingIndicator.isIndeterminate = true
        paginationLoadingIndicator.isDisplayedWhenStopped = false
        paginationLoadingIndicator.setAccessibilityLabel("Loading older messages")
        transcriptDocumentView.addSubview(paginationLoadingIndicator)
        // Estimated row frames lay out underneath the document but must not
        // reach the first paint. The readiness gate reveals one exact snapshot.
        transcriptDocumentView.alphaValue = 0
        transcriptDocumentView.setAccessibilityHidden(true)
        verticalScroller?.isEnabled = false

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            Self.onMain { self?.viewportDidScroll() }
        }
        liveScrollObservers = [
            NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Self.onMain {
                    self?.cancelDisclosureViewportAnchor()
                    self?.bottomJumpGate.cancel()
                    self?.isLiveScrolling = true
                    self?.isHandlingUserInput = true
                    self?.markRecentUserInput()
                }
            },
            NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                Self.onMain {
                    self?.mountedRowsUpdateRequested = false
                    self?.updateMountedRows()
                    self?.emitViewportSnapshot()
                    self?.isHandlingUserInput = false
                    self?.isLiveScrolling = false
                    self?.markRecentUserInput()
                    // The live window is correctness-complete. Use subsequent
                    // idle frames to finish preparing its directional runway.
                    self?.requestMountedRowsUpdate()
                }
            },
        ]
        applicationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.onMain { [weak self] in self?.interruptSendPresentation() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Runs observer work on the main actor: immediately when the
    /// notification arrived on the main thread (always the case for these
    /// `.main`-queue observers), or dispatched otherwise. Guarded so a stray
    /// off-main delivery cannot trap `MainActor.assumeIsolated`.
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
        for task in disclosureExitTasks.values { task.cancel() }
        sendPresentationWatchdog?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        for observer in liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let applicationObserver {
            NotificationCenter.default.removeObserver(applicationObserver)
        }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // AppKit may already have reset the clip bounds before this callback.
        // Re-publish the last intentional position with fresh measurement
        // caches; never sample teardown geometry here.
        if newWindow == nil, window != nil {
            republishLastStableScrollState()
            interruptSendPresentation()
            isDetaching = true
            uninstallPresentationFrameDriver()
        } else if newWindow != nil {
            isDetaching = false
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installPresentationFrameDriver()
        }
    }

    override func layout() {
        super.layout()
        guard !isDetaching else { return }
        let width = contentView.bounds.width
        guard width > 0 else { return }
        guard !isPreparingInitialProjection else { return }
        if abs(width - lastViewportWidth) > 0.5 {
            lastViewportWidth = width
            _ = activateMeasurementCacheIfNeeded()
            refreshMountedRootViews()
            rebuildDocumentGeometry()
        } else {
            applyPendingInitialPositionIfPossible()
            updateMountedRows()
        }
        startPendingSendAnimationIfPossible()
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
    }

    override func scrollWheel(with event: NSEvent) {
        guard initialPresentationGate.isReady else { return }
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isHandlingUserInput = true
        markRecentUserInput()
        let snapshotGeneration = viewportSnapshotGeneration
        super.scrollWheel(with: event)
        if viewportSnapshotGeneration == snapshotGeneration {
            emitViewportSnapshot()
        }
        isHandlingUserInput = false
        markRecentUserInput()
    }

    override func keyDown(with event: NSEvent) {
        let scrollKeys: Set<UInt16> = [115, 116, 119, 121, 123, 124, 125, 126]
        guard scrollKeys.contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        guard initialPresentationGate.isReady else { return }
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isHandlingUserInput = true
        markRecentUserInput()
        let snapshotGeneration = viewportSnapshotGeneration
        super.keyDown(with: event)
        if viewportSnapshotGeneration == snapshotGeneration {
            emitViewportSnapshot()
        }
        isHandlingUserInput = false
        markRecentUserInput()
    }

    var effectiveRowWidth: CGFloat {
        let availableWidth = max(1, contentView.bounds.width - Self.horizontalPadding * 2)
        return min(Self.maxRowWidth, availableWidth)
    }

    var transcriptRowsOrigin: CGFloat {
        paginationHeaderLayout.rowOrigin(topPadding: Self.topPadding, rowOffset: 0)
    }

    var isDraggingScrollerKnob: Bool {
        verticalScroller?.hitPart == .knob
    }

    var canPrepareRunwayRows: Bool {
        initialPresentationGate.isReady && !inLiveResize
    }

    var disclosureTimingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
    }

}

/// Presentation-only shell for the bounded set of worked rows that were
/// already mounted when an active turn settled. It cannot receive input, and
/// its flipped coordinates preserve every host's document-space frame while
/// the shared mask retracts from the bottom edge toward the header.
final class TranscriptDisclosureCollapseContainer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }
}
