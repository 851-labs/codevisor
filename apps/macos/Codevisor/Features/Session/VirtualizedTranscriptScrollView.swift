// swiftlint:disable file_length type_body_length

import AppKit
import CodevisorCore
import MarkdownCore
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
    private static let rowSpacing: CGFloat = 20
    private static let topPadding: CGFloat = 28
    private static let horizontalPadding: CGFloat = 24
    private static let maxRowWidth: CGFloat = 832
    private static let initialRunwayViewportCount: CGFloat = 1.5
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3
    private static let sendAnimationDuration: CFTimeInterval = 0.46
    private static let sendAssistantHoldAnimationKey = "codevisor.send-assistant-hold"

    private let transcriptDocumentView = FlippedTranscriptDocumentView()
    private let streamingTextFrameClock = StreamingTextAnimationFrameClock()
    private let paginationLoadingIndicator = NSProgressIndicator()
    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var projectedRows: [TranscriptVirtualRow] = []
    private var projectedRowsVersion: UInt64?
    private var activeRows: [TranscriptVirtualRow] = []
    private var activeRowsVersion: UInt64?
    private var activeRowsRange: Range<Int>?
    private var virtualLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: rowSpacing)
    /// Measured row heights plus staleness. The ledger's invariant is the fix
    /// for settled rows whose content keeps changing (background subagents
    /// streaming into an ended turn): a revision change keeps the old height
    /// as stale layout geometry instead of reverting the row to its estimate.
    private var measurements = TranscriptMeasurementLedger()
    /// Settled-row height snapshots shared copy-on-write with scroll state.
    /// Position updates can therefore publish synchronously without walking
    /// the transcript or copying these dictionaries on every trackpad frame.
    private var settledRowHeightSnapshot: [String: SessionMeasuredRow] = [:]
    private var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]] = [:]
    private var measurementCacheLRU: [SessionMeasurementCacheKey] = []
    private var activeMeasurementCacheKey: SessionMeasurementCacheKey?
    private var layoutFingerprint = 0

    private var mountedHosts: [String: TranscriptMountedRowHost] = [:]
    private var recycledHosts: [TranscriptRowHost] = []
    /// Detached hosts remain immediately reusable. Hosts exceeding the warm
    /// pool are released one at a time after the gesture.
    private var retiringHosts: [TranscriptRowHost] = []
    private let markdownHostCache = TranscriptMarkdownHostCache()
    private var recycledMarkdownHosts: [TranscriptMarkdownRowHost] = []
    private let virtualWindowPolicy = TranscriptVirtualWindowPolicy()
    /// The desired pixel runway and the last runway known to be fully laid
    /// out. Keeping both makes a window transition two-phase: prepare the new
    /// runway first, then retire the previous one.
    private var virtualWindowHandoff = TranscriptVirtualWindowHandoff()
    private var pendingWindowScrollDelta: CGFloat = 0
    private var lastObservedViewportTop: CGFloat?
    private var runwayMotion = TranscriptRunwayMotion()
    private var remainingMountsThisFrame = 2
    private var remainingRunwayPreparationsThisFrame = 1
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var markdownRowStyle = TranscriptMarkdownRowStyle(
        markdown: .default,
        appTheme: .system
    )
    private var pendingMeasuredHeights: [String: CGFloat] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    private weak var sessionController: SessionController?
    private var presentationFrameDriverToken: TranscriptFrameDriverToken?
    private var presentationDisplayLink: CADisplayLink?
    private var displayFrameRequested = false
    private var modelPresentationFrameRequested = false
    private var mountedRowsUpdateRequested = false
    private var initialPresentationGate = TranscriptInitialPresentationGate()
    /// A warm surface keeps displaying its last exact snapshot until both the
    /// newly-created outer and active projection scopes have caught up. This
    /// avoids replacing retained block rows with their provisional aggregate
    /// row during reattachment.
    private var isAwaitingWarmProjection = false
    private var initialBottomPin = TranscriptInitialBottomPin()
    private var bottomJumpGate = TranscriptBottomJumpGate()
    private var disclosureViewportAnchor: TranscriptDisclosureViewportAnchor?
    private var disclosureAnchorReleaseTask: Task<Void, Never>?

    private var pendingInitialState: SessionScrollState?
    /// The saved bottom-distance stays authoritative through initial layout,
    /// reverse pagination, and asynchronous height measurement. It is cleared
    /// only by direct user scrolling or an explicit jump to the latest content.
    private var lockedRestoreDistance: CGFloat?
    private var initialPositionConfigured = false
    private var initialPositionApplied = false
    private var followsLatest = true
    private var hasOlderHistory = false
    private var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
    private var isLoadingInitialHistory = false
    private var isPreparingInitialProjection = true
    /// The outer row projection initially contains one aggregate `.active` row.
    /// Keep first paint closed until its independently parsed block rows replace
    /// that provisional topology; otherwise an uncached chat visibly jumps from
    /// the aggregate estimate to the final block layout.
    private var isActiveProjectionPending = false
    private var scrollCommand = TranscriptScrollCommand()
    private var receivedSendAnimationToken: UInt64?
    private var pendingSendAnimationRequest: UserSendAnimationRequest?
    private var pendingSendAnimationRowKey: String?
    /// Layout before the optimistic user row was inserted. It is retained
    /// until the target row has exact geometry, then used only to animate
    /// presentation layers; the scroll position and virtual layout are already
    /// committed at the bottom.
    private var pendingSendSourceLayout: VirtualTranscriptLayout?
    private var activeSendAnimationRequest: UserSendAnimationRequest?
    private var activeSendSourceLayout: VirtualTranscriptLayout?
    private var sendPresentationLifecycle = TranscriptSendPresentationLifecycle()
    private var sendPresentationWatchdog: Task<Void, Never>?
    private var sendAnimationCompletion: TranscriptSendAnimationCompletion?
    private var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    private var reduceMotion = false
    /// Geometry changes and their compensating scroll are one transaction.
    /// The depth (rather than a Bool) keeps nested position restorations from
    /// briefly looking like user input to the bounds-change observer.
    private var positionApplicationDepth = 0
    private var isApplyingPosition: Bool { positionApplicationDepth > 0 }
    private var isHandlingUserInput = false
    private var isLiveScrolling = false
    /// AppKit can deliver the clip-view bounds notification after
    /// `scrollWheel(with:)` returns. Keep a short intent window so that delayed
    /// notification is still classified as user movement, not a system scroll.
    private var userInputDeadline: TimeInterval = 0
    private var lastDistanceFromBottom: CGFloat = 0
    private var lastBottomState: Bool?
    private var lastViewportWidth: CGFloat = 0
    private var lastPrefetchOldestKey: String?
    private var isDetaching = false
    /// Last position that was intentionally established by the user, an
    /// initial restore, or an explicit bottom command. AppKit sends bounds
    /// notifications for layout and teardown too; those must never replace it.
    private var lastStableScrollState: SessionScrollState?
    private var viewportSnapshotGeneration: UInt64 = 0
    private var boundsObserver: NSObjectProtocol?
    private var liveScrollObservers: [NSObjectProtocol] = []
    private var applicationObserver: NSObjectProtocol?

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?
    var onInitialPresentationReady: (() -> Void)?
    var isInitialPresentationReady: Bool { initialPresentationGate.isReady }
    private var maximumMountsPerFrame: Int {
        let isHighRefresh = (window?.screen?.maximumFramesPerSecond ?? 60) > 60
        if isLiveScrolling || isHandlingUserInput {
            return isHighRefresh ? 2 : 4
        }
        return isHighRefresh ? 6 : 8
    }
    private var mountWorkBudget: CFTimeInterval {
        let isHighRefresh = (window?.screen?.maximumFramesPerSecond ?? 60) > 60
        if isLiveScrolling || isHandlingUserInput {
            return isHighRefresh ? 0.0025 : 0.005
        }
        return isHighRefresh ? 0.004 : 0.008
    }
    private var maximumRunwayPreparationsPerFrame: Int {
        let isHighRefresh = (window?.screen?.maximumFramesPerSecond ?? 60) > 60
        let viewportHeight = max(1, contentView.bounds.height)
        let projectedDistance = abs(
            runwayMotion.projectedDelta(
                timestamp: CACurrentMediaTime(),
                maximumDistance: viewportHeight * 3
            )
        )
        if projectedDistance >= viewportHeight {
            return isHighRefresh ? 3 : 4
        }
        if projectedDistance >= viewportHeight * 0.35 {
            return isHighRefresh ? 2 : 3
        }
        return isHighRefresh ? 1 : 2
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
                    TranscriptPerformanceProfiler.shared.beginScrolling(in: self?.window)
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
                    TranscriptPerformanceProfiler.shared.endScrolling(in: self?.window)
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

    func configure(
        sessionController newSessionController: SessionController,
        rows newProjectedRows: [TranscriptVirtualRow],
        activeRows newActiveRows: [TranscriptVirtualRow],
        activeRowsVersion newActiveRowsVersion: UInt64,
        rowsVersion newRowsVersion: UInt64,
        initialState: SessionScrollState?,
        followsLatest newFollowsLatest: Bool,
        hasOlderHistory newHasOlderHistory: Bool,
        showsOlderHistoryLoadingIndicator newShowsOlderHistoryLoadingIndicator: Bool,
        isLoadingInitialHistory newIsLoadingInitialHistory: Bool,
        isPreparingInitialProjection newIsPreparingInitialProjection: Bool,
        isActiveProjectionPending newIsActiveProjectionPending: Bool,
        layoutFingerprint newLayoutFingerprint: Int,
        scrollCommand newScrollCommand: TranscriptScrollCommand,
        sendAnimationRequest newSendAnimationRequest: UserSendAnimationRequest?,
        reduceMotion newReduceMotion: Bool,
        markdownRowStyle newMarkdownRowStyle: TranscriptMarkdownRowStyle,
        claimSendAnimation newClaimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void
    ) {
        if sessionController !== newSessionController {
            uninstallPresentationFrameDriver()
            sessionController = newSessionController
            installPresentationFrameDriver()
        }
        self.rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        // Pagination feedback describes the fetch, not row projection. Apply
        // it even when the native document is waiting for projected rows so a
        // completed request can never leave the indicator running.
        updatePaginationLoadingIndicator(
            isPresented: newShowsOlderHistoryLoadingIndicator
        )
        isLoadingInitialHistory = newIsLoadingInitialHistory
        isPreparingInitialProjection = newIsPreparingInitialProjection
        isActiveProjectionPending = newIsActiveProjectionPending
        if isAwaitingWarmProjection,
            newIsPreparingInitialProjection || newIsActiveProjectionPending
        {
            needsLayout = true
            return
        }
        isAwaitingWarmProjection = false
        guard !newIsPreparingInitialProjection else {
            needsLayout = true
            return
        }
        let projectedRowsChanged = projectedRowsVersion != newRowsVersion
        let activeRowsChanged = activeRowsVersion != newActiveRowsVersion
        hasOlderHistory = newHasOlderHistory
        let paginationHeaderReservationChanged = paginationHeaderLayout.reserveIfNeeded(
            hasOlderHistory: newHasOlderHistory,
            isPresented: newShowsOlderHistoryLoadingIndicator
        )
        positionPaginationLoadingIndicator()
        reduceMotion = newReduceMotion
        markdownRowStyle = newMarkdownRowStyle
        claimSendAnimation = newClaimSendAnimation

        if newSendAnimationRequest?.token != receivedSendAnimationToken {
            finishSendPresentation()
            receivedSendAnimationToken = newSendAnimationRequest?.token
            pendingSendAnimationRequest = newSendAnimationRequest
            pendingSendAnimationRowKey = nil
            pendingSendSourceLayout = newSendAnimationRequest == nil ? nil : virtualLayout
        }
        if let request = pendingSendAnimationRequest {
            let requestedKey = TranscriptVirtualRow.ID.message(request.messageID).layoutKey
            if newProjectedRows.contains(where: {
                $0.layoutKey == requestedKey && $0.isUserMessage
            }) {
                pendingSendAnimationRowKey = requestedKey
            }
        }

        let layoutFingerprintChanged = layoutFingerprint != newLayoutFingerprint
        layoutFingerprint = newLayoutFingerprint

        if !initialPositionConfigured {
            initialPositionConfigured = true
            pendingInitialState = initialState
            lastStableScrollState = initialState
            initialBottomPin.configure(
                restoresNonBottomPosition: initialState.map { !$0.isAtBottom } ?? false
            )
            followsLatest = initialState?.followMode.followsLatest ?? newFollowsLatest
            if let initialState, !initialState.isAtBottom {
                lockedRestoreDistance = initialState.distanceFromBottom
            }
            if let initialState {
                measurementCaches = initialState.measurementCaches
                measurementCacheLRU = initialState.measurementCacheLRU.filter {
                    initialState.measurementCaches[$0] != nil
                }
                activeMeasurementCacheKey = nil
            }
            scrollCommand = newScrollCommand
        }

        let rebuiltRows: Bool
        if projectedRowsChanged || layoutFingerprintChanged {
            projectedRows = newProjectedRows
            projectedRowsVersion = newRowsVersion
            activeRows = newActiveRows
            activeRowsVersion = newActiveRowsVersion
            let resolution = resolvedRows(
                projectedRows: newProjectedRows,
                activeRows: newActiveRows
            )
            activeRowsRange = resolution.activeRange
            rebuiltRows = applyRows(
                resolution.rows,
                layoutFingerprintChanged: layoutFingerprintChanged
            )
        } else if activeRowsChanged {
            activeRowsVersion = newActiveRowsVersion
            rebuiltRows = applyActiveRows(newActiveRows)
        } else {
            rebuiltRows = false
        }
        if paginationHeaderReservationChanged, !rebuiltRows {
            rebuildDocumentGeometry()
        }

        if newScrollCommand != scrollCommand {
            scrollCommand = newScrollCommand
            lockedRestoreDistance = nil
            followsLatest = true
            scrollToBottom()
        }

        applyPendingInitialPositionIfPossible()
        startPendingSendAnimationIfPossible()
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
        checkForHistoryPrefetch()
    }

    @discardableResult
    private func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool
    ) -> Bool {
        // Compare only layout identity/estimates. Deep equality here would
        // walk every historical Markdown string whenever the container
        // updates. Mounted hosts receive fresh content below; unmounted rows
        // remain inert until they enter the overscan window.
        let geometryChanged =
            rows.count != newRows.count
            || zip(rows, newRows).contains { old, new in
                old.id != new.id
                    || old.estimatedHeight != new.estimatedHeight
                    || old.measurementRevision != new.measurementRevision
            }
        let previousRowsByKey = rowByKey
        if geometryChanged || layoutFingerprintChanged {
            transferActiveHeightIfNeeded(from: rows, to: newRows)
            invalidateChangedMeasurements(
                previousRowsByKey: previousRowsByKey,
                newRows: newRows
            )
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            _ = activateMeasurementCacheIfNeeded()
            for row in newRows {
                if case let .bottomSpacer(height) = row.content {
                    measurements.setExact(height, for: row.layoutKey)
                }
            }
            if layoutFingerprintChanged {
                refreshMountedRootViews()
            } else {
                refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            }
            rebuildDocumentGeometry()
            return true
        }

        rows = newRows
        rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
    }

    @discardableResult
    private func applyActiveRows(_ newActiveRows: [TranscriptVirtualRow]) -> Bool {
        let resolution = resolvedRows(
            projectedRows: projectedRows,
            activeRows: newActiveRows
        )
        defer {
            activeRows = newActiveRows
            activeRowsRange = resolution.activeRange
        }
        guard let oldRange = activeRowsRange,
            let newRange = resolution.activeRange,
            oldRange.count == newRange.count
        else {
            return applyRows(resolution.rows, layoutFingerprintChanged: false)
        }

        let previousRows = Array(rows[oldRange])
        let replacement = Array(resolution.rows[newRange])
        guard zip(previousRows, replacement).allSatisfy({ $0.layoutKey == $1.layoutKey }) else {
            return applyRows(resolution.rows, layoutFingerprintChanged: false)
        }

        let previousRowsByKey = Dictionary(
            uniqueKeysWithValues: previousRows.map { ($0.layoutKey, $0) }
        )
        rows.replaceSubrange(oldRange, with: replacement)
        for row in replacement {
            rowByKey[row.layoutKey] = row
        }
        refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        return false
    }

    private func resolvedRows(
        projectedRows: [TranscriptVirtualRow],
        activeRows: [TranscriptVirtualRow]
    ) -> (rows: [TranscriptVirtualRow], activeRange: Range<Int>?) {
        guard
            let activeIndex = projectedRows.firstIndex(where: {
                if case .active = $0.id { true } else { false }
            })
        else { return (projectedRows, nil) }
        guard case let .active(messageID) = projectedRows[activeIndex].id,
            activeRows.first?.id.messageID == messageID
        else { return (projectedRows, activeIndex..<(activeIndex + 1)) }

        var result = projectedRows
        result.replaceSubrange(activeIndex...activeIndex, with: activeRows)
        return (result, activeIndex..<(activeIndex + activeRows.count))
    }

    /// Recreates the reference app's shared-element handoff without moving the
    /// virtual row's authoritative frame: its presentation layer starts at the
    /// bottom chrome's top edge, then eases into the row's final transcript
    /// slot. That origin naturally follows the queue panel while it is visible.
    /// Keeping layout geometry final throughout the flight means streaming and
    /// scroll compensation cannot fight the animation.
    private func startPendingSendAnimationIfPossible() {
        guard let request = pendingSendAnimationRequest,
            let rowKey = pendingSendAnimationRowKey,
            let claimSendAnimation
        else { return }

        func claimAndClear() -> Bool {
            let claimed = claimSendAnimation(request)
            pendingSendAnimationRequest = nil
            pendingSendAnimationRowKey = nil
            pendingSendSourceLayout = nil
            return claimed
        }

        // Reduced motion still consumes the request exactly once, but it does
        // not need viewport geometry because no presentation flight will run.
        guard !reduceMotion else {
            _ = claimAndClear()
            finishSendPresentation()
            return
        }

        // makeNSView is configured before SwiftUI gives a newly promoted chat
        // real bounds. Its overscan window can still mount the target host at
        // placeholder geometry, so host existence alone is not readiness.
        // Keep the token pending until first-position restoration and a real
        // viewport have completed; layout() calls us again at that boundary.
        guard initialPositionApplied,
            contentView.bounds.width > 0,
            contentView.bounds.height > 0,
            let host = mountedHosts[rowKey],
            host.isPresentationReady,
            sendHistoryDestinationIsReady(
                sourceLayout: pendingSendSourceLayout,
                rowKey: rowKey
            )
        else { return }

        let sourceLayout = pendingSendSourceLayout
        let bottomSpacerHeight =
            rows.last { $0.id == .bottomSpacer }.flatMap { row -> CGFloat? in
                guard case let .bottomSpacer(height) = row.content else { return nil }
                return height
            } ?? 0
        // The spacer includes 24 pt of transcript breathing room in addition
        // to the measured bottom overlay. Its inverse lands the bubble just
        // above the queue/accessory stack (or the composer when it is alone).
        let sourceY = contentView.bounds.maxY - bottomSpacerHeight + 48
        let travel = sourceY - host.frame.minY

        // Valid geometry can legitimately leave no visible distance to travel.
        // Consume that no-op only after readiness, never during placeholder
        // layout where the same value would incorrectly spend the first send.
        guard travel > 1 else {
            _ = claimAndClear()
            finishSendPresentation()
            return
        }

        guard let layer = host.layer else { return }

        // Claim only when the real target host is ready. The controller keeps
        // this claim across representable rebuilds, preventing the same
        // request from replaying on a replacement NSView.
        guard claimAndClear() else {
            finishSendPresentation()
            return
        }

        layer.removeAnimation(forKey: "codevisor.user-send")
        beginSendPresentation(request: request, sourceLayout: sourceLayout)

        let movement = CABasicAnimation(keyPath: "transform.translation.y")
        movement.fromValue = travel
        movement.toValue = 0
        movement.duration = Self.sendAnimationDuration
        movement.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [movement, fade]
        group.duration = Self.sendAnimationDuration
        group.fillMode = .backwards
        group.isRemovedOnCompletion = true
        let completion = TranscriptSendAnimationCompletion { [weak self] _ in
            self?.finishSendPresentation(token: request.token)
        }
        sendAnimationCompletion = completion
        group.delegate = completion
        layer.add(group, forKey: "codevisor.user-send")
    }

    private func beginSendPresentation(
        request: UserSendAnimationRequest,
        sourceLayout: VirtualTranscriptLayout?
    ) {
        finishSendPresentation()
        activeSendAnimationRequest = request
        activeSendSourceLayout = sourceLayout
        let now = CACurrentMediaTime()
        let deadline = sendPresentationLifecycle.begin(token: request.token, at: now)
        scheduleSendPresentationWatchdog(token: request.token, deadline: deadline, now: now)

        if let sourceLayout {
            for (key, host) in mountedHosts {
                guard
                    let translation = TranscriptSendHistoryTransition.translationY(
                        forKey: key,
                        from: sourceLayout,
                        to: virtualLayout
                    ),
                    translation > 1,
                    let layer = host.layer
                else { continue }
                layer.removeAnimation(forKey: "codevisor.send-history-shift")
                let movement = CABasicAnimation(keyPath: "transform.translation.y")
                movement.fromValue = translation
                movement.toValue = 0
                movement.duration = TranscriptSendAnimationContract.duration
                movement.timingFunction = CAMediaTimingFunction(
                    controlPoints: Float(TranscriptSendAnimationContract.controlPoint1.x),
                    Float(TranscriptSendAnimationContract.controlPoint1.y),
                    Float(TranscriptSendAnimationContract.controlPoint2.x),
                    Float(TranscriptSendAnimationContract.controlPoint2.y)
                )
                movement.fillMode = .backwards
                movement.isRemovedOnCompletion = true
                layer.add(movement, forKey: "codevisor.send-history-shift")
            }
        }
        synchronizeSendAssistantVisibility()
    }

    private func synchronizeSendAssistantVisibility() {
        guard activeSendAnimationRequest != nil else { return }
        let sourceLayout = activeSendSourceLayout
        for (key, host) in mountedHosts {
            guard rowByKey[key]?.id.isActiveRow == true,
                sourceLayout?.indexByKey[key] == nil,
                host.layer != nil
            else { continue }
            holdSendPresentation(for: host)
        }
    }

    private func finishSendPresentation() {
        _ = sendPresentationLifecycle.cancel()
        clearSendPresentationVisuals()
    }

    private func finishSendPresentation(token: UInt64) {
        guard sendPresentationLifecycle.complete(token: token) else { return }
        clearSendPresentationVisuals()
    }

    private func clearSendPresentationVisuals() {
        sendPresentationWatchdog?.cancel()
        sendPresentationWatchdog = nil
        for host in mountedHosts.values {
            guard let layer = host.layer else { continue }
            layer.removeAnimation(forKey: "codevisor.user-send")
            layer.removeAnimation(forKey: "codevisor.send-history-shift")
            layer.removeAnimation(forKey: Self.sendAssistantHoldAnimationKey)
            layer.opacity = 1
            assert(layer.opacity == 1)
        }
        for host in recycledHosts {
            host.layer?.removeAnimation(forKey: "codevisor.user-send")
            host.layer?.removeAnimation(forKey: "codevisor.send-history-shift")
            host.layer?.removeAnimation(forKey: Self.sendAssistantHoldAnimationKey)
            host.layer?.opacity = 1
            assert(host.layer?.opacity == 1)
        }
        for host in retiringHosts {
            host.layer?.removeAnimation(forKey: "codevisor.user-send")
            host.layer?.removeAnimation(forKey: "codevisor.send-history-shift")
            host.layer?.removeAnimation(forKey: Self.sendAssistantHoldAnimationKey)
            host.layer?.opacity = 1
            assert(host.layer?.opacity == 1)
        }
        activeSendAnimationRequest = nil
        activeSendSourceLayout = nil
        sendAnimationCompletion = nil
    }

    private func holdSendPresentation(for host: TranscriptMountedRowHost) {
        guard let layer = host.layer else { return }
        // The model layer is authoritative content state and must never become
        // invisible. This finite presentation animation delays painting only;
        // interruption or expiry reveals the model value automatically.
        layer.opacity = 1
        assert(layer.opacity == 1)
        if layer.animation(forKey: Self.sendAssistantHoldAnimationKey) == nil {
            let hold = CABasicAnimation(keyPath: "opacity")
            hold.fromValue = 0
            hold.toValue = 0
            hold.duration = TranscriptSendAnimationContract.presentationSafetyDuration
            hold.isRemovedOnCompletion = true
            layer.add(hold, forKey: Self.sendAssistantHoldAnimationKey)
        }
    }

    private func scheduleSendPresentationWatchdog(
        token: UInt64,
        deadline: TimeInterval,
        now: TimeInterval
    ) {
        sendPresentationWatchdog?.cancel()
        sendPresentationWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled, let self,
                self.sendPresentationLifecycle.isExpired(
                    token: token,
                    at: CACurrentMediaTime()
                )
            else { return }
            self.finishSendPresentation(token: token)
        }
    }

    private func interruptSendPresentation() {
        if let pendingSendAnimationRequest, let claimSendAnimation {
            _ = claimSendAnimation(pendingSendAnimationRequest)
        }
        pendingSendAnimationRequest = nil
        pendingSendAnimationRowKey = nil
        pendingSendSourceLayout = nil
        finishSendPresentation()
    }

    /// Starts a new SwiftUI ownership lifetime without discarding the native
    /// presentation. Version counters are local to each SwiftUI tree, so make
    /// their first complete projection authoritative even if its number happens
    /// to equal the previous owner's last counter.
    func prepareForPresentationAttachment() {
        isAwaitingWarmProjection = initialPresentationGate.isReady
        projectedRowsVersion = nil
        activeRowsVersion = nil
    }

    func prepareForDismantle() {
        persistViewport()
        isDetaching = true
        uninstallPresentationFrameDriver()
        interruptSendPresentation()
        rowContent = nil
        claimSendAnimation = nil
        onViewportChange = nil
        onBottomStateChange = nil
        onFollowStateChange = nil
        onNearTop = nil
        onInitialPresentationReady = nil
    }

    private func installPresentationFrameDriver() {
        guard presentationDisplayLink == nil, let window, let sessionController else { return }
        let maximumFramesPerSecond = max(1, window.screen?.maximumFramesPerSecond ?? 60)
        let displayLink = displayLink(
            target: self,
            selector: #selector(presentationDisplayLinkDidFire(_:))
        )
        let rate = Float(maximumFramesPerSecond)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: rate,
            maximum: rate,
            preferred: rate
        )
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        presentationDisplayLink = displayLink
        streamingTextFrameClock.setFrameRequester { [weak self] in
            self?.requestDisplayFrame()
        }
        presentationFrameDriverToken = sessionController.registerTranscriptFrameDriver(
            maximumFramesPerSecond: maximumFramesPerSecond
        ) { [weak self] in
            self?.requestModelPresentationFrame()
        }
        if !pendingMeasuredHeights.isEmpty || !retiringHosts.isEmpty {
            requestDisplayFrame()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowScreenDidChange(_:)),
            name: NSWindow.didChangeScreenNotification,
            object: window
        )
    }

    @objc private func windowScreenDidChange(_: Notification) {
        reinstallPresentationFrameDriver()
    }

    private func reinstallPresentationFrameDriver() {
        uninstallPresentationFrameDriver()
        installPresentationFrameDriver()
    }

    private func uninstallPresentationFrameDriver() {
        streamingTextFrameClock.setFrameRequester(nil)
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        presentationDisplayLink?.invalidate()
        presentationDisplayLink = nil
        displayFrameRequested = false
        modelPresentationFrameRequested = false
        mountedRowsUpdateRequested = false
        if let presentationFrameDriverToken {
            sessionController?.unregisterTranscriptFrameDriver(presentationFrameDriverToken)
            self.presentationFrameDriverToken = nil
        }
    }

    private func requestDisplayFrame() {
        guard let presentationDisplayLink else { return }
        displayFrameRequested = true
        presentationDisplayLink.isPaused = false
    }

    private func requestModelPresentationFrame() {
        modelPresentationFrameRequested = true
        requestDisplayFrame()
    }

    private func requestMountedRowsUpdate() {
        guard presentationDisplayLink != nil, !inLiveResize else {
            updateMountedRows()
            return
        }
        mountedRowsUpdateRequested = true
        requestDisplayFrame()
    }

    @objc private func presentationDisplayLinkDidFire(_ displayLink: CADisplayLink) {
        let shouldPresentModel = modelPresentationFrameRequested
        let shouldUpdateMountedRows = mountedRowsUpdateRequested
        remainingMountsThisFrame = maximumMountsPerFrame
        remainingRunwayPreparationsThisFrame = maximumRunwayPreparationsPerFrame
        displayFrameRequested = false
        modelPresentationFrameRequested = false
        mountedRowsUpdateRequested = false
        if shouldPresentModel, let presentationFrameDriverToken {
            sessionController?.transcriptPresentationFrameDidFire(presentationFrameDriverToken)
        }
        if shouldUpdateMountedRows {
            updateMountedRows()
        }
        if !pendingMeasuredHeights.isEmpty {
            commitPendingMeasurements()
        }
        streamingTextFrameClock.tick(at: displayLink.timestamp)
        if !isLiveScrolling, !isHandlingUserInput {
            drainRetiringHosts(limit: 1)
        }
        if !retiringHosts.isEmpty {
            requestDisplayFrame()
        }
        displayLink.isPaused = !displayFrameRequested
    }

    private func sendHistoryDestinationIsReady(
        sourceLayout: VirtualTranscriptLayout?,
        rowKey: String
    ) -> Bool {
        guard let sourceLayout,
            sourceLayout.indexByKey[rowKey] == nil,
            sourceLayout.keys.contains(where: { $0.hasPrefix("message:") }),
            let targetIndex = rows.firstIndex(where: { $0.layoutKey == rowKey })
        else { return true }
        return rows[targetIndex...].allSatisfy { row in
            let key = row.layoutKey
            guard row.id != .bottomSpacer else { return true }
            guard let host = mountedHosts[key] else { return false }
            return measurements[key] != nil
                && !measurements.isStale(key)
                && host.isAttachmentGeometryReady
                && host.isPresentationReady
        }
    }

    func persistViewport() {
        guard !isDetaching else {
            republishLastStableScrollState()
            return
        }
        // NSViewRepresentable calls this while the clip view still owns its
        // live bounds. Capture the final compensated coordinate, including
        // measurements learned since the user's last wheel event, before
        // AppKit begins teardown.
        emitViewportSnapshot()
    }

    private func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow]
    ) {
        guard let oldActive = oldRows.first(where: { $0.id.isActiveRow }),
            let activeHeight = measurements[oldActive.layoutKey],
            !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
        else { return }
        let oldKeys = Set(oldRows.map(\.layoutKey))
        let insertedSettledRows = newRows.filter {
            $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
        }
        // One active host can transfer its aggregate height only when it
        // settles into one row. A plan turn intentionally becomes multiple
        // independently measured rows, so assigning the aggregate to any one
        // slice would poison scroll geometry.
        guard insertedSettledRows.count == 1,
            let settledActive = insertedSettledRows.first,
            measurements[settledActive.layoutKey] == nil
        else { return }
        // Provisional, never authoritative: the settled render (auto-collapsed
        // worked section, answer hoisted out of it) differs from the streaming
        // render, so the streaming height positions rows until the settled
        // host measures — but it must not be written into revision-keyed
        // caches where it could outlive this mount as an "exact" measurement.
        measurements.setProvisional(activeHeight, for: settledActive.layoutKey)
    }

    private func invalidateChangedMeasurements(
        previousRowsByKey: [String: TranscriptVirtualRow],
        newRows: [TranscriptVirtualRow]
    ) {
        for row in newRows {
            guard row.id.isCacheableSettledRow,
                let previous = previousRowsByKey[row.layoutKey],
                previous.measurementRevision != row.measurementRevision
            else { continue }
            let key = row.layoutKey
            // The last measured height stays in the ledger as stale layout
            // geometry: a settled row whose content keeps changing (a
            // background subagent streaming into an ended turn bumps this
            // revision on every flush) must never snap back to its flat
            // estimate and let its unclipped content overlap the rows below.
            measurements.markStale(key)
            settledRowHeightSnapshot.removeValue(forKey: key)
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey]?.removeValue(forKey: key)
            }
            // Mounted content is replaced immediately after invalidation.
            // `installRootView` performs the one required fresh measurement;
            // invalidating here as well used to schedule the same TextKit and
            // hosting-controller work twice for every settled revision.
        }
    }

    private var effectiveRowWidth: CGFloat {
        let availableWidth = max(1, contentView.bounds.width - Self.horizontalPadding * 2)
        return min(Self.maxRowWidth, availableWidth)
    }

    /// Switches to the exact measurements for the current text layout. At
    /// most three width/typography variants survive, which handles ordinary
    /// sidebar toggling without allowing per-session memory to grow forever.
    @discardableResult
    private func activateMeasurementCacheIfNeeded() -> Bool {
        guard contentView.bounds.width > 0 else { return false }
        let key = SessionMeasurementCacheKey(
            rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
            layoutFingerprint: layoutFingerprint
        )
        guard key != activeMeasurementCacheKey else { return false }

        activeMeasurementCacheKey = key
        measurementCacheLRU.removeAll { $0 == key }
        measurementCacheLRU.append(key)
        while measurementCacheLRU.count > Self.maxMeasurementCacheCount {
            let evicted = measurementCacheLRU.removeFirst()
            measurementCaches.removeValue(forKey: evicted)
        }

        // Keep mounted heights as provisional geometry while their independent
        // inner hosts remeasure at the new width. Provisional values are not
        // written into the new width's cache — but they are marked stale, so
        // a host whose height happens to be identical at the new width still
        // commits it into that width's cache instead of being deduped away.
        let provisionalMountedHeights = Dictionary(
            uniqueKeysWithValues: mountedHosts.keys.compactMap { key in
                measurements[key].map { (key, $0) }
            })
        measurements.removeAll(keepingCapacity: true)
        let cached = measurementCaches[key] ?? [:]
        var valid: [String: SessionMeasuredRow] = [:]
        valid.reserveCapacity(cached.count)
        for row in rows {
            let rowKey = row.layoutKey
            guard row.id.isCacheableSettledRow,
                let measurement = cached[rowKey],
                measurement.revision == row.measurementRevision,
                measurement.height > 0
            else { continue }
            valid[rowKey] = measurement
            measurements.setExact(measurement.height, for: rowKey)
        }
        settledRowHeightSnapshot = valid
        measurementCaches[key] = valid
        for row in rows {
            if case let .bottomSpacer(height) = row.content {
                measurements.setExact(height, for: row.layoutKey)
            }
        }
        for (key, height) in provisionalMountedHeights where measurements[key] == nil {
            measurements.setProvisional(height, for: key)
        }
        // ChatGPT restores the exact height map that produced its saved
        // coordinate before mounting the saved rendered window. Apply it only
        // when the width/typography key still matches; current measurements
        // replace these provisional values as soon as the hosts lay out.
        if let restore = pendingInitialState?.virtualTranscript,
            restore.measurementCacheKey == key
        {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey] else { continue }
                // A settled row's saved height is applied only when its
                // revision still matches: content can change while the pane
                // is closed (a background subagent streaming into an ended
                // turn), and the snapshot must not restore that stale height
                // as if it were current. Mismatches fall back to the
                // revision-checked cache entry applied above, or the estimate.
                if row.id.isCacheableSettledRow {
                    guard
                        restore.settledRowsByKey[rowKey]?.revision
                            == row.measurementRevision
                    else { continue }
                }
                measurements.setProvisional(height, for: rowKey)
            }
        }
        return true
    }

    /// Rebuilds `virtualLayout` and re-anchors the viewport.
    ///
    /// `changedHeights` is the streaming fast path: when the only difference
    /// from the current layout is a set of committed row heights (row set and
    /// order unchanged — height commits never add or remove rows), the layout
    /// is patched incrementally instead of reconstructed. The full rebuild
    /// re-materializes and re-hashes every row key — O(transcript) string
    /// work on the main thread for what is usually a one-row height change
    /// several times per second per streaming chat.
    private func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
        let performanceToken = TranscriptPerformanceProfiler.shared.begin(
            in: window,
            identity: TranscriptPerformanceIdentity(
                rowKey: "transcript",
                kind: changedHeights == nil
                    ? "full geometry"
                    : "geometry · \(changedHeights?.count ?? 0) heights"
            ),
            phase: .geometry
        )
        defer { TranscriptPerformanceProfiler.shared.end(performanceToken) }
        // Capture the viewport before changing document size. A locked restore
        // target wins until the user deliberately scrolls. Once the reader has
        // moved away from the bottom, preserve the first visible row instead
        // of preserving a raw bottom distance: streaming growth below that row
        // must not pull the viewport down with it.
        let previousLayout = virtualLayout
        let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
        // ChatGPT follows the bottom only while the latest turn is live. An
        // idle transcript is static even when its distance is zero, so opening
        // a disclosure preserves the reader's viewport instead of pushing the
        // clicked header offscreen.
        let followsStreamingLatest = followsLatest && rows.contains { $0.id.isActiveRow }
        // Composer geometry is represented by the final spacer row. If its
        // measured height settles while the reader is already at the bottom,
        // keep the latest content stationary; ordinary idle-row changes still
        // preserve their visible block anchor below.
        let pinsBottomSpacerChange =
            previousDistance.map { $0 <= Self.atBottomThreshold } == true
            && bottomSpacerGeometryWillChange(from: previousLayout)
        let pinsBottom =
            bottomJumpGate.isActive
            || initialBottomPin.isActive
            || pinsBottomSpacerChange
        let visibleAnchorKey: String?
        if !pinsBottom,
            !followsStreamingLatest,
            let previousDistance,
            !previousLayout.isEmpty
        {
            let visibleRange = previousLayout.visibleRange(
                distanceFromBottom: previousDistance,
                viewportHeight: contentView.bounds.height,
                overscanCount: 0
            )
            // Match ChatGPT's compensation rule: prefer a visible row whose
            // height is already measured, then fall back to the first visible
            // key. Estimates must not become an anchor when an exact row is
            // available in the same viewport.
            visibleAnchorKey =
                visibleRange.compactMap { index -> String? in
                    guard previousLayout.keys.indices.contains(index) else { return nil }
                    let key = previousLayout.keys[index]
                    return measurements[key] == nil ? nil : key
                }.first
                ?? visibleRange.first.flatMap { index in
                    previousLayout.keys.indices.contains(index) ? previousLayout.keys[index] : nil
                }
        } else {
            visibleAnchorKey = nil
        }
        let distanceToPreserve: CGFloat? =
            if let lockedRestoreDistance {
                lockedRestoreDistance
            } else if pinsBottom {
                0
            } else if initialPositionApplied {
                followsStreamingLatest ? 0 : currentDistanceFromBottom()
            } else {
                nil
            }
        var initialRestoreRange: Range<Int>?
        applyPositionTransaction {
            virtualLayout =
                incrementallyUpdatedLayout(changedHeights: changedHeights)
                ?? VirtualTranscriptLayout(
                    items: rows.map {
                        .init(
                            key: $0.layoutKey,
                            estimatedHeight: $0.estimatedHeight,
                            spacingAfter: $0.spacingAfter
                        )
                    },
                    measuredHeights: measurements.heightsByKey,
                    spacing: Self.rowSpacing
                )
            initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
                virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
            }

            let width = max(1, contentView.bounds.width)
            transcriptDocumentView.frame = CGRect(
                x: 0,
                y: 0,
                width: width,
                height: paginationHeaderLayout.documentHeight(
                    topPadding: Self.topPadding,
                    rowsHeight: virtualLayout.totalHeight
                )
            )
            positionPaginationLoadingIndicator()
            let firstChangedIndex = changedHeights?.keys.compactMap {
                virtualLayout.indexByKey[$0]
            }.min()
            positionMountedRows(startingAt: firstChangedIndex)

            if !initialPositionApplied {
                applyPendingInitialPositionIfPossible()
            } else if let anchor = disclosureViewportAnchor {
                setViewportTop(anchor.viewportTop)
            } else if let distanceToPreserve {
                let anchoredDistance =
                    pinsBottom
                    ? nil
                    : visibleAnchorKey.flatMap { key in
                        virtualLayout.distanceFromBottom(
                            preservingAnchor: key,
                            previousLayout: previousLayout,
                            previousDistanceFromBottom: distanceToPreserve
                        )
                    }
                let resolvedDistance = anchoredDistance ?? distanceToPreserve
                if lockedRestoreDistance != nil {
                    lockedRestoreDistance = resolvedDistance
                }
                setDistanceFromBottom(resolvedDistance)
            }
            // A delayed bounds notification after this transaction sees the
            // final canonical distance, not the transient pre-compensation one.
            lastDistanceFromBottom = currentDistanceFromBottom()
        }
        if initialRestoreRange != nil || changedHeights == nil || mountedCoverageNeedsUpdate() {
            updateMountedRows(rangeOverride: initialRestoreRange)
        }
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
    }

    private func bottomSpacerGeometryWillChange(
        from previousLayout: VirtualTranscriptLayout
    ) -> Bool {
        let key = TranscriptVirtualRow.ID.bottomSpacer.layoutKey
        guard let previousIndex = previousLayout.indexByKey[key],
            previousLayout.heights.indices.contains(previousIndex),
            let row = rowByKey[key]
        else { return false }
        let nextHeight = measurements[key] ?? row.estimatedHeight
        return abs(previousLayout.heights[previousIndex] - nextHeight) > 0.5
    }

    /// The current layout with only the given heights patched, or nil when a
    /// full rebuild is required (row set drifted, a key is unknown, or there
    /// is no hint). Guarded so a mismatch can never produce stale geometry:
    /// the row count must match and every changed key must already exist.
    private func incrementallyUpdatedLayout(
        changedHeights: [String: CGFloat]?
    ) -> VirtualTranscriptLayout? {
        guard let changedHeights, !changedHeights.isEmpty,
            !virtualLayout.isEmpty,
            virtualLayout.keys.count == rows.count
        else { return nil }
        return virtualLayout.updatingHeights(changedHeights)
    }

    private func mountedCoverageNeedsUpdate() -> Bool {
        let targetRange = plannedMountedRange()
        let targetKeys = keys(in: targetRange)
        if targetKeys != virtualWindowHandoff.targetKeys { return true }
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: contentView.bounds.height,
            overscanCount: 0
        )
        return visibleRange.contains { index in
            guard virtualLayout.keys.indices.contains(index) else { return false }
            return mountedHosts[virtualLayout.keys[index]] == nil
        }
    }

    private func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, contentView.bounds.height > 0 else { return }

        let shouldPublishInitialPosition =
            lastStableScrollState == nil
            || (pendingInitialState?.isAtBottom == true && followsLatest)

        let restoredRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
            virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
        }
        // Mount the same neighborhood that was present when the coordinate was
        // saved. Otherwise estimates can select a different part of the thread
        // and the first measurement pass starts from the wrong content.
        updateMountedRows(rangeOverride: restoredRange)

        if let state = pendingInitialState, !state.isAtBottom {
            if let restoredTop = restoredViewportTop(from: state) {
                setViewportTop(restoredTop)
                // Subsequent asynchronous measurements preserve the restored
                // anchor from this resolved coordinate, not the stale fallback
                // distance that preceded it.
                lockedRestoreDistance = currentDistanceFromBottom()
            } else {
                let maximumDistance = max(
                    0,
                    transcriptDocumentView.frame.height - contentView.bounds.height
                )
                if state.distanceFromBottom > maximumDistance + 0.5, hasOlderHistory {
                    setViewportTop(0)
                    checkForHistoryPrefetch(force: true)
                    return
                }
                setDistanceFromBottom(state.distanceFromBottom)
            }
            publishBottomState(currentDistanceFromBottom() <= Self.atBottomThreshold)
        } else {
            lockedRestoreDistance = nil
            setDistanceFromBottom(0)
        }

        initialPositionApplied = true
        pendingInitialState = nil
        updateMountedRows(rangeOverride: restoredRange)
        // A saved target is already the authoritative persisted state. Do not
        // replace it with a clamped/intermediate first-layout coordinate.
        if shouldPublishInitialPosition {
            emitViewportSnapshot()
        }
    }

    private func currentDistanceFromBottom() -> CGFloat {
        max(0, transcriptDocumentView.frame.height - contentView.bounds.maxY)
    }

    private var transcriptRowsOrigin: CGFloat {
        paginationHeaderLayout.rowOrigin(topPadding: Self.topPadding, rowOffset: 0)
    }

    private func currentViewportAnchor() -> VirtualTranscriptAnchor? {
        virtualLayout.viewportAnchor(
            at: contentView.bounds.minY - transcriptRowsOrigin
        )
    }

    private func restoredViewportTop(from state: SessionScrollState) -> CGFloat? {
        guard let anchor = state.virtualTranscript?.viewportAnchor,
            let rowRelativeTop = virtualLayout.viewportTop(restoring: anchor)
        else { return nil }
        return transcriptRowsOrigin + rowRelativeTop
    }

    private func setDistanceFromBottom(_ distance: CGFloat) {
        let viewportHeight = contentView.bounds.height
        let documentHeight = transcriptDocumentView.frame.height
        setViewportTop(max(0, documentHeight - viewportHeight - max(0, distance)))
    }

    private func setViewportTop(_ requestedTop: CGFloat) {
        let maximum = max(0, transcriptDocumentView.frame.height - contentView.bounds.height)
        let top = min(max(0, requestedTop), maximum)
        guard abs(contentView.bounds.minY - top) > 0.25 else { return }
        applyPositionTransaction {
            contentView.scroll(to: CGPoint(x: 0, y: top))
            reflectScrolledClipView(contentView)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
    }

    private func applyPositionTransaction(_ body: () -> Void) {
        positionApplicationDepth += 1
        defer { positionApplicationDepth -= 1 }
        body()
    }

    private func scrollToBottom() {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        commitPendingMeasurements()
        bottomJumpGate.begin()
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
        resolveBottomJumpIfPossible()
    }

    private func viewportDidScroll() {
        // AppKit can resize the clip view again after `viewWillMove(nil)`.
        // That teardown geometry is not a user position and must never replace
        // the valid snapshot captured immediately before detachment.
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance
        publishVisibleRowsToPerformanceProfiler(distanceFromBottom: distance)
        let viewportTop = contentView.bounds.minY
        let isUserMovement = isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling
        if let lastObservedViewportTop, isUserMovement {
            pendingWindowScrollDelta += viewportTop - lastObservedViewportTop
            runwayMotion.observe(
                viewportTop: viewportTop,
                timestamp: CACurrentMediaTime()
            )
        } else if !isApplyingPosition {
            pendingWindowScrollDelta = 0
            if runwayMotion.pointsPerSecond == 0 {
                runwayMotion.reset(
                    viewportTop: viewportTop,
                    timestamp: CACurrentMediaTime()
                )
            }
        }
        lastObservedViewportTop = viewportTop
        if isDraggingScrollerKnob || isHandlingUserInput || isLiveScrolling {
            // Native scrolling may deliver more bounds changes than the screen
            // can present. Reconcile the virtual window once on the next real
            // display frame; the prepared pixel runway covers that handoff.
            requestMountedRowsUpdate()
        } else {
            updateMountedRows()
        }

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let isRecentUserMovement =
            isHandlingUserInput || isLiveScrolling
            || ProcessInfo.processInfo.systemUptime <= userInputDeadline
        // Only recent user movement can change follow intent. The short intent
        // window still catches AppKit bounds notifications delivered after the
        // wheel/key callback, while remount and remeasurement geometry cannot
        // silently turn follow off.
        if !isApplyingPosition, isRecentUserMovement,
            distance > previousDistance + 0.5, followsLatest
        {
            followsLatest = false
            onFollowStateChange?(false)
        } else if !isApplyingPosition, isRecentUserMovement, atBottom, !followsLatest {
            followsLatest = true
            onFollowStateChange?(true)
        }

        // Persist only while AppKit is dispatching an actual user scrolling
        // event. Bounds changes also fire for document resize, restoration,
        // and teardown; treating those as user position is what reset chats
        // to the first row during navigation.
        if !isApplyingPosition, isHandlingUserInput || isLiveScrolling {
            lockedRestoreDistance = nil
            // A live scroll (including knob tracking) publishes one exact
            // snapshot in didEndLiveScroll. Rebuilding it for every bounds
            // tick adds work without making restoration more accurate.
            if !isLiveScrolling {
                emitViewportSnapshot()
            }
        }
        checkForHistoryPrefetch()
    }

    private var isDraggingScrollerKnob: Bool {
        verticalScroller?.hitPart == .knob
    }

    private func markRecentUserInput() {
        userInputDeadline = ProcessInfo.processInfo.systemUptime + 0.35
    }

    private func publishBottomState(_ isAtBottom: Bool) {
        guard lastBottomState != isAtBottom else { return }
        lastBottomState = isAtBottom
        onBottomStateChange?(isAtBottom)
    }

    private func checkForHistoryPrefetch(force: Bool = false) {
        guard !rows.isEmpty else { return }
        let distanceFromTop = contentView.bounds.minY
        let threshold = max(600, contentView.bounds.height * 1.5)
        if !force, distanceFromTop > threshold {
            if distanceFromTop > threshold * 1.25 {
                lastPrefetchOldestKey = nil
            }
            return
        }
        let oldestKey = rows.first?.layoutKey
        guard force || oldestKey != lastPrefetchOldestKey else { return }
        lastPrefetchOldestKey = oldestKey
        onNearTop?()
    }

    private func plannedMountedRange(scrollDelta: CGFloat = 0) -> Range<Int> {
        let distance = currentDistanceFromBottom()
        if !initialPresentationGate.isReady {
            let runway = contentView.bounds.height * Self.initialRunwayViewportCount
            return virtualLayout.visibleRange(
                distanceFromBottom: distance,
                viewportHeight: contentView.bounds.height,
                runwayBefore: runway,
                runwayAfter: runway
            )
        }
        return virtualWindowPolicy.targetRange(
            layout: virtualLayout,
            distanceFromBottom: distance,
            viewportHeight: contentView.bounds.height,
            scrollDelta: scrollDelta,
            currentRange: windowRange(for: virtualWindowHandoff.targetKeys)
        )
    }

    private func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || contentView.bounds.height > 0 else { return }
        let profiler = TranscriptPerformanceProfiler.shared
        let windowIdentity = TranscriptPerformanceIdentity(
            rowKey: "transcript",
            kind: "virtual window"
        )
        let performanceToken = profiler.begin(
            in: window,
            identity: windowIdentity,
            phase: .windowUpdate
        )
        defer { profiler.end(performanceToken) }
        let reconciliation: (mountPlan: TranscriptVirtualWindowMountPlan, targetChanged: Bool) =
            profiler.measure(
                in: window,
                identity: windowIdentity,
                phase: .windowReconcile
            ) {
                virtualWindowHandoff.retainOnlyValidKeys { rowByKey[$0] != nil }
                let observedScrollDelta = rangeOverride == nil ? pendingWindowScrollDelta : 0
                pendingWindowScrollDelta = 0
                let projectedScrollDelta =
                    rangeOverride == nil
                    ? runwayMotion.projectedDelta(
                        timestamp: CACurrentMediaTime(),
                        maximumDistance: contentView.bounds.height * 3
                    )
                    : 0
                let scrollDelta =
                    abs(projectedScrollDelta) > abs(observedScrollDelta)
                    ? projectedScrollDelta
                    : observedScrollDelta
                let targetRange =
                    rangeOverride
                    ?? plannedMountedRange(scrollDelta: scrollDelta)
                let visibleRange = virtualLayout.visibleRange(
                    distanceFromBottom: currentDistanceFromBottom(),
                    viewportHeight: contentView.bounds.height,
                    overscanCount: 0
                )
                // A restored or rapidly changing target should normally contain the
                // viewport, but make visible coverage an invariant even if it does not.
                let retainedIndices = Set(targetRange).union(visibleRange)
                let targetKeys = Set(
                    retainedIndices.compactMap { index in
                        virtualLayout.keys.indices.contains(index)
                            ? virtualLayout.keys[index]
                            : nil
                    })
                let targetChanged = targetKeys != virtualWindowHandoff.targetKeys
                if targetChanged {
                    virtualWindowHandoff.setTarget(targetKeys)
                }
                return (
                    virtualWindowPolicy.mountPlan(
                        targetRange: targetRange,
                        visibleRange: visibleRange,
                        scrollDelta: scrollDelta
                    ),
                    targetChanged
                )
            }
        let mountPlan = reconciliation.mountPlan
        let usesFrameBudget = presentationDisplayLink != nil && !inLiveResize
        let mountStarted = CACurrentMediaTime()
        // Loaded viewport rows are never optional. Mount and flush all of them
        // before this native scroll frame can be presented; applying the frame
        // budget here is what exposed transparent document space at speed.
        for index in mountPlan.visibleIndices {
            mountRow(at: index, requiresImmediatePresentation: true)
        }
        assert(
            mountPlan.visibleIndices.allSatisfy { index in
                guard virtualLayout.keys.indices.contains(index) else { return false }
                return mountedHosts[virtualLayout.keys[index]] != nil
            },
            "Loaded transcript viewport must be fully mounted"
        )

        // Complete the closest directional runway rows one at a time. Mounting
        // a collection of hosts before laying any of them out consumed the
        // frame budget on root installation and left the nearest rows unable
        // to present when momentum carried them into the viewport.
        prepareRunwayRowsEndToEnd(
            at: mountPlan.runwayIndices,
            workStartedAt: mountStarted,
            usesFrameBudget: usesFrameBudget
        )
        // Rows from an abandoned intermediate target are neither the last
        // complete window nor part of the window currently being prepared.
        if reconciliation.targetChanged {
            retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
        }
        promoteTargetWindowAndRetireIfReady()
        profiler.measure(
            in: window,
            identity: windowIdentity,
            phase: .windowScheduling
        ) {
            let needsRunwayPreparation =
                canPrepareRunwayRows
                && virtualWindowHandoff.targetKeys.contains { key in
                    mountedHosts[key]?.needsRunwayPreparation == true
                }
            if usesFrameBudget,
                virtualWindowHandoff.targetKeys.contains(where: { mountedHosts[$0] == nil })
                    || needsRunwayPreparation
            {
                requestMountedRowsUpdate()
            }
            synchronizeSendAssistantVisibility()
        }
    }

    private var canPrepareRunwayRows: Bool {
        initialPresentationGate.isReady && !inLiveResize
    }

    /// A mounted runway is useful only after its SwiftUI/AppKit subtree has
    /// completed first layout. Directional rows are prepared on display-link
    /// frames even during live scrolling, but both the count and elapsed work
    /// remain bounded. The viewport keeps its synchronous no-blank fallback.
    private func prepareRunwayRowsEndToEnd(
        at indices: [Int],
        workStartedAt: CFTimeInterval,
        usesFrameBudget: Bool
    ) {
        for index in indices {
            if usesFrameBudget,
                remainingMountsThisFrame == 0,
                remainingRunwayPreparationsThisFrame == 0
            {
                break
            }
            guard virtualLayout.keys.indices.contains(index) else { continue }
            if usesFrameBudget,
                CACurrentMediaTime() - workStartedAt >= mountWorkBudget
            {
                break
            }
            let key = virtualLayout.keys[index]
            if mountedHosts[key] == nil {
                guard !usesFrameBudget || remainingMountsThisFrame > 0 else {
                    continue
                }
                if mountRow(at: index, requiresImmediatePresentation: false), usesFrameBudget {
                    remainingMountsThisFrame -= 1
                }
            }
            guard let host = mountedHosts[key], host.needsRunwayPreparation else { continue }
            guard canPrepareRunwayRows else { continue }
            guard !usesFrameBudget || remainingRunwayPreparationsThisFrame > 0 else {
                continue
            }
            TranscriptPerformanceProfiler.shared.measure(
                in: window,
                identity: performanceIdentity(for: rowByKey[key], fallbackKey: key),
                phase: .runwayLayout
            ) {
                host.prepareForImmediatePresentation()
            }
            if usesFrameBudget { remainingRunwayPreparationsThisFrame -= 1 }
        }
    }

    @discardableResult
    private func mountRow(
        at index: Int,
        requiresImmediatePresentation: Bool
    ) -> Bool {
        guard virtualLayout.keys.indices.contains(index) else { return false }
        let key = virtualLayout.keys[index]
        let identity = performanceIdentity(for: rowByKey[key], fallbackKey: key)
        if let host = mountedHosts[key] {
            if requiresImmediatePresentation, !host.isPresentationReady {
                TranscriptPerformanceProfiler.shared.measure(
                    in: window,
                    identity: identity,
                    phase: .visibleLayout
                ) {
                    host.prepareForImmediatePresentation()
                }
            }
            return false
        }
        guard let row = rowByKey[key] else { return false }
        if usesNativeMarkdownHost(for: row) {
            return mountMarkdownRow(
                row,
                at: index,
                identity: identity,
                requiresImmediatePresentation: requiresImmediatePresentation
            )
        }

        let profiler = TranscriptPerformanceProfiler.shared
        let host: TranscriptRowHost
        if recycledHosts.isEmpty, retiringHosts.isEmpty {
            host = profiler.measure(
                in: window,
                identity: identity,
                phase: .hostConstruction
            ) {
                TranscriptRowHost(frame: .zero)
            }
        } else {
            host = profiler.measure(
                in: window,
                identity: identity,
                phase: .hostReuse
            ) {
                if let retiring = retiringHosts.popLast() {
                    retiring
                } else {
                    recycledHosts.removeLast()
                }
            }
        }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostPreparation
        ) {
            host.prepareForMountedRow()
            host.performanceIdentity = identity
            host.onHeightChange = { [weak self] height in
                self?.recordMeasuredHeight(height, for: key)
            }
        }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostInsertion
        ) {
            transcriptDocumentView.addSubview(host)
            mountedHosts[key] = host
        }
        // Position and push the content width before assigning the root view.
        // Otherwise its first TextKit measurement can race the 1pt placeholder.
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostPosition
        ) {
            position(host: host, at: index)
            host.syncContentWidth()
        }
        let rootView = profiler.measure(
            in: window,
            identity: identity,
            phase: .rootConstruction
        ) {
            measuredRootView(for: row)
        }
        let knownHeight: CGFloat? =
            if row.id.isCacheableSettledRow,
                let measuredHeight = measurements[key],
                !measurements.isStale(key)
            {
                measuredHeight
            } else {
                nil
            }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .rootInstall
        ) {
            host.installRootView(rootView, knownHeight: knownHeight)
        }
        if requiresImmediatePresentation {
            profiler.measure(
                in: window,
                identity: identity,
                phase: .visibleLayout
            ) {
                host.prepareForImmediatePresentation()
            }
        }
        return true
    }

    private func usesNativeMarkdownHost(for row: TranscriptVirtualRow) -> Bool {
        guard case let .markdownChunk(chunk) = row.content else { return false }
        return chunk.lifecycle == .settled
    }

    private func mountMarkdownRow(
        _ row: TranscriptVirtualRow,
        at index: Int,
        identity: TranscriptPerformanceIdentity,
        requiresImmediatePresentation: Bool
    ) -> Bool {
        guard case let .markdownChunk(chunk) = row.content else { return false }
        let key = row.layoutKey
        let profiler = TranscriptPerformanceProfiler.shared
        let host: TranscriptMarkdownRowHost
        if let prepared = markdownHostCache.take(for: key) {
            host = profiler.measure(
                in: window,
                identity: identity,
                phase: .hostReuse
            ) { prepared }
        } else if let recycled = recycledMarkdownHosts.popLast() {
            host = profiler.measure(
                in: window,
                identity: identity,
                phase: .hostReuse
            ) { recycled }
        } else {
            host = profiler.measure(
                in: window,
                identity: identity,
                phase: .hostConstruction
            ) { TranscriptMarkdownRowHost(frame: .zero) }
        }

        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostPreparation
        ) {
            host.prepareForMountedRow()
            host.performanceIdentity = identity
            host.onHeightChange = { [weak self] height in
                self?.recordMeasuredHeight(height, for: key)
            }
        }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostInsertion
        ) {
            transcriptDocumentView.addSubview(host)
            mountedHosts[key] = host
        }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostPosition
        ) {
            position(host: host, at: index)
        }
        let knownHeight: CGFloat? =
            if let measuredHeight = measurements[key], !measurements.isStale(key) {
                measuredHeight
            } else {
                nil
            }
        profiler.measure(
            in: window,
            identity: identity,
            phase: .rootInstall
        ) {
            host.setContent(
                chunk,
                streamID: key,
                style: markdownRowStyle,
                knownHeight: knownHeight
            )
        }
        if requiresImmediatePresentation, !host.isPresentationReady {
            profiler.measure(
                in: window,
                identity: identity,
                phase: .visibleLayout
            ) {
                host.prepareForImmediatePresentation()
            }
        }
        return true
    }

    private func publishVisibleRowsToPerformanceProfiler(distanceFromBottom: CGFloat) {
        let profiler = TranscriptPerformanceProfiler.shared
        guard profiler.isEnabled(in: window) else { return }
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: distanceFromBottom,
            viewportHeight: contentView.bounds.height,
            overscanCount: 0
        )
        profiler.setVisibleRows(
            visibleRange.compactMap { index in
                guard virtualLayout.keys.indices.contains(index) else { return nil }
                let key = virtualLayout.keys[index]
                return performanceIdentity(for: rowByKey[key], fallbackKey: key)
            },
            in: window
        )
    }

    private func performanceIdentity(
        for row: TranscriptVirtualRow?,
        fallbackKey: String
    ) -> TranscriptPerformanceIdentity {
        guard let row else {
            return TranscriptPerformanceIdentity(rowKey: fallbackKey, kind: "unknown")
        }
        let kind: String =
            switch row.content {
            case let .markdownChunk(markdown):
                if markdown.blocks.count == 1, let block = markdown.blocks.first {
                    "\(markdownPerformanceKind(block)) · block \(markdown.ordinal)"
                } else {
                    "prose chunk · \(markdown.blocks.count) blocks · block \(markdown.ordinal)"
                }
            case .message: "message"
            case .assistantPlanning: "assistant planning"
            case .planDocument: "plan document"
            case .planHeader: "plan header"
            case .assistantResult: "assistant result"
            case .assistantChrome: "assistant chrome"
            case .assistantAttachment: "attachment"
            case .active: "active message"
            case .setup: "session setup"
            case .optimistic: "optimistic message"
            case .backgroundTask: "background task"
            case .updateGate: "update gate"
            case .connecting: "connecting"
            case .serverWait: "server wait"
            case .error: "error"
            case .bottomSpacer: "bottom spacer"
            }
        return TranscriptPerformanceIdentity(rowKey: row.layoutKey, kind: kind)
    }

    private func markdownPerformanceKind(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(level, text): "heading h\(level) · \(text.plainText.count)c"
        case let .paragraph(text): "paragraph · \(text.plainText.count)c"
        case let .codeBlock(_, code, _):
            "code · \(code.reduce(into: 1) { $0 += $1 == "\n" ? 1 : 0 }) lines"
        case let .bulletList(items): "bullet list · \(items.count) items"
        case let .orderedList(items): "ordered list · \(items.count) items"
        case let .list(list): "nested list · \(list.items.count) roots"
        case let .blockQuote(blocks): "blockquote · \(blocks.count) blocks"
        case let .table(headers, _, rows):
            "table · \(rows.count + 1)x\(headers.count)"
        case .thematicBreak: "thematic break"
        }
    }

    private func windowRange(for keys: Set<String>) -> Range<Int>? {
        guard !keys.isEmpty else { return nil }
        let indices = keys.compactMap { virtualLayout.indexByKey[$0] }.sorted()
        guard indices.count == keys.count,
            let first = indices.first,
            let last = indices.last,
            last - first + 1 == indices.count
        else { return nil }
        return first..<(last + 1)
    }

    private func keys(in range: Range<Int>) -> Set<String> {
        Set(
            range.compactMap { index in
                virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
            }
        )
    }

    private func promoteTargetWindowIfReady() -> Bool {
        guard virtualWindowHandoff.presentedKeys != virtualWindowHandoff.targetKeys else {
            return false
        }
        return virtualWindowHandoff.promoteIfReady { key in
            guard let host = mountedHosts[key] else { return false }
            return measurements[key] != nil
                && !measurements.isStale(key)
                && pendingMeasuredHeights[key] == nil
                && host.isAttachmentGeometryReady
                && host.isPresentationReady
        }
    }

    @discardableResult
    private func promoteTargetWindowAndRetireIfReady() -> Bool {
        let profiler = TranscriptPerformanceProfiler.shared
        let identity = TranscriptPerformanceIdentity(
            rowKey: "transcript",
            kind: "virtual window"
        )
        let promoted = profiler.measure(
            in: window,
            identity: identity,
            phase: .windowPromotion
        ) {
            promoteTargetWindowIfReady()
        }
        guard promoted else { return false }
        retireMountedHosts(excluding: virtualWindowHandoff.retainedKeys)
        return true
    }

    private func retireMountedHosts(excluding retainedKeys: Set<String>) {
        let obsoleteKeys = mountedHosts.keys.filter { !retainedKeys.contains($0) }
        guard !obsoleteKeys.isEmpty else { return }
        let profiler = TranscriptPerformanceProfiler.shared
        let identity = TranscriptPerformanceIdentity(
            rowKey: "transcript",
            kind: "virtual window"
        )
        profiler.measure(
            in: window,
            identity: identity,
            phase: .hostRetirement
        ) {
            for key in obsoleteKeys {
                guard let host = mountedHosts.removeValue(forKey: key) else { continue }
                host.removeFromSuperviewWithoutNeedingDisplay()
                storeDetachedHost(host, for: key)
            }
        }
        if !retiringHosts.isEmpty { requestDisplayFrame() }
    }

    private func storeDetachedHost(_ host: TranscriptMountedRowHost, for key: String) {
        host.onHeightChange = nil
        if let markdownHost = host as? TranscriptMarkdownRowHost {
            let evicted = markdownHostCache.insert(
                markdownHost,
                for: key,
                height: host.frame.height,
                maximumTotalHeight: max(1, contentView.bounds.height * 12)
            )
            for host in evicted {
                if recycledMarkdownHosts.count < 8 {
                    recycledMarkdownHosts.append(host)
                }
            }
        } else if let hosted = host as? TranscriptRowHost {
            retiringHosts.append(hosted)
        }
    }

    private func drainRetiringHosts(limit: Int) {
        for _ in 0..<max(0, limit) {
            guard let host = retiringHosts.popLast() else { return }
            if recycledHosts.count < 8 {
                recycledHosts.append(host)
            }
            // Once the warm pool is full, dropping this final reference tears
            // the host down here, outside live scrolling. The per-frame limit
            // prevents a large abandoned window from becoming one idle hitch.
        }
    }

    private func refreshMountedRootViews() {
        refreshMountedHosts(previousRowsByKey: nil)
    }

    private func refreshChangedMountedRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        refreshMountedHosts(previousRowsByKey: previousRowsByKey)
    }

    private func refreshMountedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow]?
    ) {
        var replacementKeys: [String] = []
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key] else { continue }
            if let previousRowsByKey {
                guard let previous = previousRowsByKey[key],
                    previous.content != row.content
                        || previous.measurementRevision != row.measurementRevision
                else { continue }
            }

            let wantsNativeMarkdown = usesNativeMarkdownHost(for: row)
            let isNativeMarkdown = host is TranscriptMarkdownRowHost
            guard wantsNativeMarkdown == isNativeMarkdown else {
                invalidateMeasurementForRendererTransition(key)
                replacementKeys.append(key)
                continue
            }

            if let markdownHost = host as? TranscriptMarkdownRowHost,
                case let .markdownChunk(chunk) = row.content
            {
                let knownHeight: CGFloat? =
                    if let height = measurements[key], !measurements.isStale(key) {
                        height
                    } else {
                        nil
                    }
                markdownHost.setContent(
                    chunk,
                    streamID: key,
                    style: markdownRowStyle,
                    knownHeight: knownHeight
                )
            } else if let hosted = host as? TranscriptRowHost {
                hosted.rootView = measuredRootView(for: row)
            }
        }

        for key in replacementKeys {
            replaceMountedHost(for: key)
        }
    }

    private func invalidateMeasurementForRendererTransition(_ key: String) {
        measurements.markStale(key)
        settledRowHeightSnapshot.removeValue(forKey: key)
        if let activeMeasurementCacheKey {
            measurementCaches[activeMeasurementCacheKey]?.removeValue(forKey: key)
        }
    }

    private func replaceMountedHost(for key: String) {
        guard let host = mountedHosts.removeValue(forKey: key),
            let index = virtualLayout.indexByKey[key]
        else { return }
        let visibleDocumentRect = NSRect(
            x: 0,
            y: contentView.bounds.minY,
            width: transcriptDocumentView.bounds.width,
            height: contentView.bounds.height
        )
        let requiresImmediatePresentation = host.frame.intersects(visibleDocumentRect)
        host.removeFromSuperviewWithoutNeedingDisplay()
        storeDetachedHost(host, for: key)
        _ = mountRow(
            at: index,
            requiresImmediatePresentation: requiresImmediatePresentation
        )
    }

    private func measuredRootView(for row: TranscriptVirtualRow) -> AnyView {
        guard let rowContent else { return AnyView(EmptyView()) }
        let key = row.layoutKey
        return AnyView(
            rowContent(row)
                .environment(\.streamingTextAnimationFrameClock, streamingTextFrameClock)
                .environment(\.transcriptPerformAnchoredDisclosureChange) { [weak self] change in
                    self?.performAnchoredDisclosureChange(in: key, change: change) ?? change()
                }
                .environment(\.transcriptInvalidateRowMeasurement) { [weak self] in
                    self?.mountedHosts[key]?.requestContentMeasurement()
                }
                .onPreferenceChange(AttachmentGeometryReadinessPreferenceKey.self) {
                    [weak self] unresolvedCount in
                    self?.attachmentGeometryReadinessDidChange(
                        unresolvedCount == 0,
                        for: key
                    )
                }
                // The hosting view's measured height is rounded up to keep
                // row geometry stable. Pin the SwiftUI root to the top so any
                // sub-point rounding slack stays below the message instead of
                // recentering it when a disclosure changes the row height.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key)
        )
    }

    private func attachmentGeometryReadinessDidChange(_ ready: Bool, for key: String) {
        guard let host = mountedHosts[key], host.setAttachmentGeometryReady(ready) else {
            return
        }
        promoteTargetWindowAndRetireIfReady()
        updateInitialPresentationReadiness()
    }

    private func performAnchoredDisclosureChange(
        in rowKey: String,
        change: @escaping () -> Void
    ) {
        guard initialPositionApplied,
            virtualLayout.indexByKey[rowKey] != nil
        else {
            change()
            return
        }

        disclosureAnchorReleaseTask?.cancel()
        let anchor = TranscriptDisclosureViewportAnchor(
            id: UUID(),
            viewportTop: contentView.bounds.minY
        )
        disclosureViewportAnchor = anchor
        change()

        disclosureAnchorReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                self?.disclosureViewportAnchor?.id == anchor.id
            else { return }
            self?.disclosureViewportAnchor = nil
            self?.disclosureAnchorReleaseTask = nil
        }
    }

    private func cancelDisclosureViewportAnchor() {
        disclosureAnchorReleaseTask?.cancel()
        disclosureAnchorReleaseTask = nil
        disclosureViewportAnchor = nil
    }

    private func recordMeasuredHeight(_ rawHeight: CGFloat, for key: String) {
        let height = max(1, rawHeight.rounded(.up))
        guard rowByKey[key] != nil else { return }
        // A stale ledger key must reach the commit even when the reported
        // height is unchanged — that commit is what clears the staleness and
        // rewrites the row's revision-keyed cache entries.
        let needsCommit =
            pendingMeasuredHeights[key].map { abs($0 - height) > 0.5 }
            ?? measurements.needsCommit(height, for: key)
        guard needsCommit else {
            // Cached settled rows can report the exact height already in the
            // ledger. Fresh AppKit layout still completes presentation gates.
            promoteTargetWindowAndRetireIfReady()
            updateInitialPresentationReadiness()
            resolveBottomJumpIfPossible()
            startPendingSendAnimationIfPossible()
            return
        }
        pendingMeasuredHeights[key] = height

        // A mounted transcript commits all height changes on its native display
        // clock. Content, following offsets, document size, and bottom
        // compensation therefore become one physical-frame transaction.
        if presentationDisplayLink != nil, !inLiveResize {
            requestDisplayFrame()
            return
        }
        guard measurementCommitTask == nil else { return }
        measurementCommitTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.commitPendingMeasurements()
        }
    }

    private func commitPendingMeasurements() {
        measurementCommitTask = nil
        let pending = pendingMeasuredHeights
        pendingMeasuredHeights.removeAll(keepingCapacity: true)
        var committedHeights: [String: CGFloat] = [:]
        for (key, height) in pending {
            guard rowByKey[key] != nil,
                measurements.needsCommit(height, for: key)
            else { continue }
            if storeMeasuredHeight(height, for: key) {
                committedHeights[key] = height
            }
        }
        if !committedHeights.isEmpty {
            // Height-only commits qualify for the incremental layout patch;
            // row-set changes always come through `configure`'s full rebuild.
            rebuildDocumentGeometry(changedHeights: committedHeights)
        }
        promoteTargetWindowAndRetireIfReady()
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
        startPendingSendAnimationIfPossible()
    }

    private func resolveBottomJumpIfPossible() {
        guard bottomJumpGate.isActive,
            initialPositionApplied,
            contentView.bounds.height > 0
        else { return }
        let requiredKeys = Set(
            plannedMountedRange().compactMap { index in
                virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
            })
        let mountedKeys = Set(mountedHosts.keys)
        guard requiredKeys.isSubset(of: mountedKeys) else {
            updateMountedRows()
            return
        }
        let resolvedKeys = Set(
            requiredKeys.filter { key in
                guard let host = mountedHosts[key] else { return false }
                return measurements[key] != nil
                    && !measurements.isStale(key)
                    && host.isAttachmentGeometryReady
                    && host.isPresentationReady
            })
        _ = bottomJumpGate.resolve(
            requiredKeys: requiredKeys,
            resolvedKeys: resolvedKeys,
            hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
        )
    }

    private func updateInitialPresentationReadiness() {
        guard !initialPresentationGate.isReady,
            !isDetaching,
            initialPositionApplied,
            contentView.bounds.height > 0
        else { return }

        let requiredKeys = Set(
            plannedMountedRange().compactMap { index in
                virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
            })
        let mountedKeys = Set(mountedHosts.keys)
        guard requiredKeys.isSubset(of: mountedKeys) else {
            updateMountedRows()
            return
        }
        let resolvedKeys = Set(
            requiredKeys.filter { key in
                guard let host = mountedHosts[key] else { return false }
                return measurements[key] != nil
                    && !measurements.isStale(key)
                    && host.isAttachmentGeometryReady
                    && host.isPresentationReady
            })
        guard
            initialPresentationGate.resolve(
                isHydrating: isLoadingInitialHistory || isPreparingInitialProjection,
                isActiveProjectionPending: isActiveProjectionPending,
                requiredKeys: requiredKeys,
                resolvedKeys: resolvedKeys,
                hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
            )
        else { return }

        applyPositionTransaction {
            if initialBottomPin.isActive {
                setDistanceFromBottom(0)
            }
            initialBottomPin.release()
            transcriptDocumentView.alphaValue = 1
            transcriptDocumentView.setAccessibilityHidden(false)
            verticalScroller?.isEnabled = true
        }
        onInitialPresentationReady?()
    }

    /// Commits one measurement into the ledger and the revision-keyed caches.
    /// Returns whether the height actually moved (geometry must rebuild); a
    /// same-height commit still refreshes caches for the row's new revision.
    @discardableResult
    private func storeMeasuredHeight(_ height: CGFloat, for key: String) -> Bool {
        let heightChanged = measurements.commit(height, for: key)
        if let row = rowByKey[key], row.id.isCacheableSettledRow {
            let measurement = SessionMeasuredRow(
                height: height,
                revision: row.measurementRevision
            )
            settledRowHeightSnapshot[key] = measurement
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey, default: [:]][key] = measurement
            }
        }
        return heightChanged
    }

    private func positionMountedRows(startingAt firstChangedIndex: Int? = nil) {
        let profiler = TranscriptPerformanceProfiler.shared
        for (key, host) in mountedHosts {
            guard let index = virtualLayout.indexByKey[key] else { continue }
            if let firstChangedIndex, index < firstChangedIndex { continue }
            let frame = rowFrame(at: index)
            guard host.frame.size != frame.size || host.frame.origin != frame.origin else {
                continue
            }
            profiler.measure(
                in: window,
                identity: performanceIdentity(for: rowByKey[key], fallbackKey: key),
                phase: .hostPosition
            ) {
                position(host: host, frame: frame)
            }
        }
    }

    private func position(host: TranscriptMountedRowHost, at index: Int) {
        position(host: host, frame: rowFrame(at: index))
    }

    private func rowFrame(at index: Int) -> CGRect {
        let viewportWidth = max(1, contentView.bounds.width)
        let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
        return CGRect(
            x: rowX,
            y: paginationHeaderLayout.rowOrigin(
                topPadding: Self.topPadding,
                rowOffset: virtualLayout.topOffsets[index]
            ),
            width: rowWidth,
            height: virtualLayout.heights[index]
        )
    }

    private func position(host: TranscriptMountedRowHost, frame: CGRect) {
        // Height commits move every later row but do not change those rows'
        // content geometry. Assigning the complete frame for a y-only move
        // needlessly invalidates AppKit/SwiftUI layout; update size and origin
        // independently so already-laid-out hosts remain clean.
        if host.frame.size != frame.size {
            host.setFrameSize(frame.size)
        }
        if host.frame.origin != frame.origin {
            host.setFrameOrigin(frame.origin)
        }
    }

    private func updatePaginationLoadingIndicator(isPresented: Bool) {
        if isPresented {
            paginationLoadingIndicator.startAnimation(nil)
        } else {
            paginationLoadingIndicator.stopAnimation(nil)
        }
        positionPaginationLoadingIndicator()
    }

    private func positionPaginationLoadingIndicator() {
        guard paginationHeaderLayout.reservesSpace else {
            paginationLoadingIndicator.frame = .zero
            return
        }
        paginationLoadingIndicator.sizeToFit()
        let size = paginationLoadingIndicator.frame.size
        paginationLoadingIndicator.frame = CGRect(
            x: (max(1, contentView.bounds.width) - size.width) / 2,
            y: Self.topPadding
                + (paginationHeaderLayout.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func emitViewportSnapshot() {
        guard !isDetaching, initialPositionConfigured,
            contentView.bounds.height > 0
        else { return }
        let distance = currentDistanceFromBottom()
        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let state = SessionScrollState(
            distanceFromBottom: distance,
            measurementCaches: measurementCaches,
            measurementCacheLRU: measurementCacheLRU,
            virtualTranscript: currentVirtualRestoreState(
                viewportAnchor: currentViewportAnchor()
            ),
            followMode: followsLatest ? .followingLatest : .staticPosition
        )
        lastStableScrollState = state
        viewportSnapshotGeneration &+= 1
        onViewportChange?(state)
    }

    private func republishLastStableScrollState() {
        guard var state = lastStableScrollState else { return }
        // Measurements learned after the last wheel event are still useful on
        // the next mount, but they do not authorize a different position.
        state.measurementCaches = measurementCaches
        state.measurementCacheLRU = measurementCacheLRU
        state.virtualTranscript = currentVirtualRestoreState(
            viewportAnchor: state.virtualTranscript?.viewportAnchor
        )
        lastStableScrollState = state
        onViewportChange?(state)
    }

    private func currentVirtualRestoreState(
        viewportAnchor: VirtualTranscriptAnchor?
    ) -> SessionVirtualTranscriptRestoreState {
        let targetKeys = virtualWindowHandoff.targetKeys
        let restoreKeys = targetKeys.isEmpty ? Set(mountedHosts.keys) : targetKeys
        let indices = restoreKeys.compactMap { virtualLayout.indexByKey[$0] }.sorted()
        let renderedWindow: SessionRenderedTranscriptWindow? = indices.first.flatMap { first in
            guard let last = indices.last,
                virtualLayout.keys.indices.contains(first)
            else { return nil }
            return SessionRenderedTranscriptWindow(
                anchorKey: virtualLayout.keys[first],
                count: last - first + 1
            )
        }
        return SessionVirtualTranscriptRestoreState(
            measurementCacheKey: activeMeasurementCacheKey,
            // Dictionary assignment is copy-on-write. Restore already ignores
            // keys absent from the current transcript, so this keeps viewport
            // snapshots O(mounted rows) instead of walking the full history.
            rowHeightsByKey: measurements.heightsByKey,
            // The revision-carrying snapshot rides along (also copy-on-write)
            // so restore can reject settled-row heights whose content changed
            // while the pane was closed.
            settledRowsByKey: settledRowHeightSnapshot,
            renderedWindow: renderedWindow,
            viewportAnchor: viewportAnchor
        )
    }
}

/// Retained for the lifetime of the Core Animation group so the assistant
/// reveal is coupled to the real user-row presentation completion.
private final class TranscriptSendAnimationCompletion: NSObject, CAAnimationDelegate {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func animationDidStop(_: CAAnimation, finished: Bool) {
        completion(finished)
    }
}
