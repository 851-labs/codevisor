// swiftlint:disable file_length type_body_length

import AppKit
import CodevisorCore
import QuartzCore
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
    private static let overscanCount = 2
    private static let initialRunwayViewportCount: CGFloat = 1.5
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3
    private static let sendAnimationDuration: CFTimeInterval = 0.46
    private static let sendAssistantHoldAnimationKey = "codevisor.send-assistant-hold"

    private let transcriptDocumentView = FlippedTranscriptDocumentView()
    private let paginationLoadingIndicator = NSHostingView(
        rootView: ShimmeringText(text: "Loading older messages...")
    )
    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
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

    private var mountedHosts: [String: TranscriptRowHost] = [:]
    private var recycledHosts: [TranscriptRowHost] = []
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasuredHeights: [String: CGFloat] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    private var initialPresentationGate = TranscriptInitialPresentationGate()
    private var bottomJumpGate = TranscriptBottomJumpGate()
    /// A scrollbar-knob drag can cross dozens of virtual windows in a single
    /// frame. Mount only the latest one at a display-friendly cadence instead
    /// of making AppKit wait for every intermediate SwiftUI host tree.
    private var knobDragMountTask: Task<Void, Never>?

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
    private var olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
    private var isLoadingInitialHistory = false
    private var isPreparingInitialProjection = true
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
    private var boundsObserver: NSObjectProtocol?
    private var liveScrollObservers: [NSObjectProtocol] = []
    private var applicationObserver: NSObjectProtocol?

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?
    private var onOlderHistoryPresented: ((UInt64) -> Void)?
    var onInitialPresentationReady: (() -> Void)?
    var isInitialPresentationReady: Bool { initialPresentationGate.isReady }
    /// The chat history itself can hold keyboard focus: a click anywhere in
    /// it (routed here by TerminalFocusController's mouse monitor) blurs a
    /// focused terminal, the scroll keys in `keyDown(with:)` keep working,
    /// and ordinary typing is handed off to the composer by the same
    /// controller's type-to-focus monitor.
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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
        paginationLoadingIndicator.isHidden = true
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
                    self?.knobDragMountTask?.cancel()
                    self?.knobDragMountTask = nil
                    self?.updateMountedRows()
                    self?.emitViewportSnapshot()
                    self?.isHandlingUserInput = false
                    self?.isLiveScrolling = false
                    self?.markRecentUserInput()
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
        measurementCommitTask?.cancel()
        knobDragMountTask?.cancel()
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
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // AppKit may already have reset the clip bounds before this callback.
        // Re-publish the last intentional position with fresh measurement
        // caches; never sample teardown geometry here.
        if newWindow == nil, window != nil {
            republishLastStableScrollState()
            interruptSendPresentation()
            isDetaching = true
        } else if newWindow != nil {
            isDetaching = false
        }
        super.viewWillMove(toWindow: newWindow)
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
        super.scrollWheel(with: event)
        emitViewportSnapshot()
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
        super.keyDown(with: event)
        emitViewportSnapshot()
        isHandlingUserInput = false
        markRecentUserInput()
    }

    func configure(
        rows newRows: [TranscriptVirtualRow],
        initialState: SessionScrollState?,
        followsLatest newFollowsLatest: Bool,
        hasOlderHistory newHasOlderHistory: Bool,
        showsOlderHistoryLoadingIndicator newShowsOlderHistoryLoadingIndicator: Bool,
        olderHistoryPresentationTarget newOlderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?,
        isLoadingInitialHistory newIsLoadingInitialHistory: Bool,
        isPreparingInitialProjection newIsPreparingInitialProjection: Bool,
        layoutFingerprint newLayoutFingerprint: Int,
        scrollCommand newScrollCommand: TranscriptScrollCommand,
        sendAnimationRequest newSendAnimationRequest: UserSendAnimationRequest?,
        reduceMotion newReduceMotion: Bool,
        claimSendAnimation newClaimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void,
        onOlderHistoryPresented: @escaping (UInt64) -> Void
    ) {
        self.rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        self.onOlderHistoryPresented = onOlderHistoryPresented
        isLoadingInitialHistory = newIsLoadingInitialHistory
        isPreparingInitialProjection = newIsPreparingInitialProjection
        guard !newIsPreparingInitialProjection else {
            needsLayout = true
            return
        }
        hasOlderHistory = newHasOlderHistory
        let paginationHeaderReservationChanged = paginationHeaderLayout.reserveIfNeeded(
            hasOlderHistory: newHasOlderHistory,
            isPresented: newShowsOlderHistoryLoadingIndicator
        )
        updatePaginationLoadingIndicator(
            isPresented: newShowsOlderHistoryLoadingIndicator
        )
        olderHistoryPresentationTarget = newOlderHistoryPresentationTarget
        reduceMotion = newReduceMotion
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
            if newRows.contains(where: {
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
            // Row-set changes mount and recycle only the affected hosts below.
            // Preserve every other hosting tree so an insertion/removal cannot
            // blank the whole visible transcript for a SwiftUI commit.
            if layoutFingerprintChanged {
                refreshMountedRootViews()
            } else {
                refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            }
            rebuildDocumentGeometry()
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            if paginationHeaderReservationChanged {
                rebuildDocumentGeometry()
            }
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
        acknowledgeOlderHistoryPresentationIfPossible()
    }

    /// AppKit applies prepended rows synchronously, but the acknowledgement is
    /// still explicit so the SwiftUI feedback lifetime ends at native document
    /// commit rather than when the request happens to return.
    private func acknowledgeOlderHistoryPresentationIfPossible() {
        guard let target = olderHistoryPresentationTarget,
            rows.first?.layoutKey == target.oldestRowKey
        else { return }
        olderHistoryPresentationTarget = nil
        onOlderHistoryPresented?(target.token)
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
        activeSendAnimationRequest = nil
        activeSendSourceLayout = nil
        sendAnimationCompletion = nil
    }

    private func holdSendPresentation(for host: TranscriptRowHost) {
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

    func prepareForDismantle() {
        persistViewport()
        isDetaching = true
        interruptSendPresentation()
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
        republishLastStableScrollState()
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
            // A mounted host must re-report even an unchanged height so the
            // stale flag clears and caches relearn the new revision; without
            // the reset, the unchanged-height dedupe swallows that report.
            if let host = mountedHosts[key] {
                host.resetReportedContentHeight()
                host.requestContentMeasurement()
            }
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
        let pinsExplicitBottom = bottomJumpGate.isActive
        let visibleAnchorKey: String?
        if !pinsExplicitBottom,
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
            } else if pinsExplicitBottom {
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
            positionMountedRows()

            if !initialPositionApplied {
                applyPendingInitialPositionIfPossible()
            } else if let anchor = disclosureViewportAnchor {
                setViewportTop(anchor.viewportTop)
            } else if let distanceToPreserve {
                let anchoredDistance =
                    pinsExplicitBottom
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
        updateMountedRows(rangeOverride: initialRestoreRange)
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
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
        var layout = virtualLayout
        for (key, height) in changedHeights {
            guard let updated = layout.updatingHeight(forKey: key, to: height) else { return nil }
            layout = updated
        }
        return layout
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
        if isDraggingScrollerKnob {
            scheduleKnobDragMountUpdate()
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

    private func scheduleKnobDragMountUpdate() {
        guard knobDragMountTask == nil else { return }
        knobDragMountTask = Task { @MainActor [weak self] in
            // The scroller itself remains fully native and tracks every event;
            // transcript host churn is capped at roughly one update per frame.
            try? await Task.sleep(for: .milliseconds(16))
            guard let self, !Task.isCancelled else { return }
            self.knobDragMountTask = nil
            self.updateMountedRows()
        }
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

    private func plannedMountedRange() -> Range<Int> {
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
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: contentView.bounds.height,
            overscanCount: 0
        )
        let overscannedRange = virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: contentView.bounds.height,
            overscanCount: Self.overscanCount
        )
        let planIndices = overscannedRange.filter { index in
            guard virtualLayout.keys.indices.contains(index),
                let row = rowByKey[virtualLayout.keys[index]]
            else { return false }
            return row.id.isPlanDocument
        }
        return VirtualTranscriptLayout.overscanRange(
            visibleRange: visibleRange,
            overscannedRange: overscannedRange,
            stoppingAt: planIndices
        )
    }

    private func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || contentView.bounds.height > 0 else { return }
        let targetRange: Range<Int>
        if let rangeOverride {
            targetRange = rangeOverride
        } else {
            targetRange = plannedMountedRange()
        }
        // Preserve a rendered window that already contains the target. This is
        // ChatGPT's rendered-range containment rule: height changes inside a
        // visible turn must not recycle that turn halfway through its update.
        let mountedIndices = mountedHosts.keys.compactMap { virtualLayout.indexByKey[$0] }
        let mountedRange: Range<Int>? = mountedIndices.min().flatMap { lower in
            mountedIndices.max().map { upper in lower..<(upper + 1) }
        }
        let range: Range<Int> =
            if rangeOverride == nil,
                let mountedRange,
                mountedRange.lowerBound <= targetRange.lowerBound,
                mountedRange.upperBound >= targetRange.upperBound
            {
                mountedRange
            } else {
                targetRange
            }
        let requiredKeys = Set(
            range.compactMap { index in
                virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
            })

        let obsoleteKeys = mountedHosts.keys.filter { !requiredKeys.contains($0) }
        for key in obsoleteKeys {
            guard let host = mountedHosts.removeValue(forKey: key) else { continue }
            host.removeFromSuperview()
            if recycledHosts.count < 8 {
                recycledHosts.append(host)
            }
        }

        for index in range {
            guard virtualLayout.keys.indices.contains(index) else { continue }
            let key = virtualLayout.keys[index]
            if mountedHosts[key] == nil, let row = rowByKey[key] {
                let host = recycledHosts.popLast() ?? TranscriptRowHost(frame: .zero)
                host.prepareForMountedRow()
                host.onHeightChange = { [weak self] height in
                    self?.recordMeasuredHeight(height, for: key)
                }
                transcriptDocumentView.addSubview(host)
                mountedHosts[key] = host
                // Position (and push the resulting width into the content
                // constraint) BEFORE installing the root view: assigning
                // `rootView` schedules the first measurement, and it must not
                // run against the 1pt placeholder width. `position` is pure
                // geometry off the virtual layout, so it needs no content.
                position(host: host, at: index)
                host.syncContentWidth()
                host.rootView = measuredRootView(for: row)
            }
        }
        synchronizeSendAssistantVisibility()
    }

    private func refreshMountedRootViews() {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key] else { continue }
            host.rootView = measuredRootView(for: row)
        }
    }

    private func refreshChangedMountedRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key], let previous = previousRowsByKey[key],
                previous.content != row.content
                    || previous.measurementRevision != row.measurementRevision
            else { continue }
            host.rootView = measuredRootView(for: row)
        }
    }

    private func measuredRootView(for row: TranscriptVirtualRow) -> AnyView {
        guard let rowContent else { return AnyView(EmptyView()) }
        let key = row.layoutKey
        return AnyView(
            rowContent(row)
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
            updateInitialPresentationReadiness()
            resolveBottomJumpIfPossible()
            startPendingSendAnimationIfPossible()
            return
        }
        pendingMeasuredHeights[key] = height

        // A streaming active row needs its latest height in the same update;
        // ordinary/history rows are committed together after SwiftUI finishes
        // the current layout pass so hosts never use mixed geometry snapshots.
        if rowByKey[key]?.id.isActiveRow == true, !inLiveResize {
            measurementCommitTask?.cancel()
            measurementCommitTask = nil
            commitPendingMeasurements()
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
                requiredKeys: requiredKeys,
                resolvedKeys: resolvedKeys,
                hasPendingMeasurements: !pendingMeasuredHeights.isEmpty
            )
        else { return }

        applyPositionTransaction {
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

    private func positionMountedRows() {
        for (key, host) in mountedHosts {
            guard let index = virtualLayout.indexByKey[key] else { continue }
            position(host: host, at: index)
        }
    }

    private func position(host: TranscriptRowHost, at index: Int) {
        let viewportWidth = max(1, contentView.bounds.width)
        let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
        let frame = CGRect(
            x: rowX,
            y: paginationHeaderLayout.rowOrigin(
                topPadding: Self.topPadding,
                rowOffset: virtualLayout.topOffsets[index]
            ),
            width: rowWidth,
            height: virtualLayout.heights[index]
        )
        if host.frame != frame {
            host.frame = frame
        }
    }

    private func updatePaginationLoadingIndicator(isPresented: Bool) {
        paginationLoadingIndicator.isHidden = !isPresented
        positionPaginationLoadingIndicator()
    }

    private func positionPaginationLoadingIndicator() {
        guard paginationHeaderLayout.reservesSpace else {
            paginationLoadingIndicator.frame = .zero
            return
        }
        let size = paginationLoadingIndicator.fittingSize
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
            virtualTranscript: currentVirtualRestoreState(),
            followMode: followsLatest ? .followingLatest : .staticPosition
        )
        lastStableScrollState = state
        onViewportChange?(state)
    }

    private func republishLastStableScrollState() {
        guard var state = lastStableScrollState else { return }
        // Measurements learned after the last wheel event are still useful on
        // the next mount, but they do not authorize a different position.
        state.measurementCaches = measurementCaches
        state.measurementCacheLRU = measurementCacheLRU
        state.virtualTranscript = currentVirtualRestoreState()
        lastStableScrollState = state
        onViewportChange?(state)
    }

    private func currentVirtualRestoreState() -> SessionVirtualTranscriptRestoreState {
        let indices = mountedHosts.keys.compactMap { virtualLayout.indexByKey[$0] }.sorted()
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
            renderedWindow: renderedWindow
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
