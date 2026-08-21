import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import TranscriptKit
import UIKit

/// A UIKit port of the macOS document-view virtualizer. UIScrollView owns only
/// touch tracking and momentum; this view is the single owner of document
/// geometry, row mounting, measurement, restoration, and anchor compensation.
@MainActor
final class VirtualizedTranscriptScrollView: UIScrollView, UIScrollViewDelegate {
    private static let rowSpacing: CGFloat = 20
    private static let topPadding: CGFloat = 12
    private static let horizontalPadding: CGFloat = 16
    private static let maxRowWidth: CGFloat = 832
    private static let overscanCount = 3
    /// Initial presentation waits for exact geometry across this much content
    /// on both sides of the viewport. The already-mounted runway makes the
    /// first fast swipe consume prepared TextKit/SwiftUI rows rather than
    /// synchronously constructing them under the user's finger.
    private static let initialRunwayViewportCount: CGFloat = 1.5
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3
    private static let maxParkedHostCount = 16
    private let canvasView = UIView()
    private let paginationLoadingIndicator = UIHostingConfiguration {
        ShimmeringText(text: "Loading older messages...")
    }
    .margins(.all, 0)
    .makeContentView()
    weak var hostingParent: UIViewController?

    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var unreadFinishedTargetByItemId: [UUID: SessionAttentionTarget] = [:]
    private var lastPresentedAttentionTarget: SessionAttentionTarget?
    private var virtualLayout = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: rowSpacing,
    )
    private var measurements = TranscriptMeasurementLedger()
    private var settledRowHeightSnapshot: [String: SessionMeasuredRow] = [:]
    private var measurementCaches: [SessionMeasurementCacheKey: [String: SessionMeasuredRow]] = [:]
    private var measurementCacheLRU: [SessionMeasurementCacheKey] = []
    private var activeMeasurementCacheKey: SessionMeasurementCacheKey?
    private var layoutFingerprint = 0

    private var mountedHosts: [String: TranscriptRowHost] = [:]
    private var parkedHosts: [String: TranscriptRowHost] = [:]
    private var parkedHostLRU: [String] = []
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasurements: [String: TranscriptRowMeasurement] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    private var measurementCommitGate = TranscriptMeasurementCommitGate()
    private var initialPresentationGate = TranscriptInitialPresentationGate()
    private var bottomJumpGate = TranscriptBottomJumpGate()
    private var deferredRowsDuringScroll: [TranscriptVirtualRow]?

    private struct DisclosureViewportAnchor {
        let id: UUID
        let viewportTop: CGFloat
    }

    private var disclosureViewportAnchor: DisclosureViewportAnchor?
    private var disclosureAnchorReleaseTask: Task<Void, Never>?

    private var pendingInitialState: SessionScrollState?
    private var lockedRestoreDistance: CGFloat?
    private var initialPositionConfigured = false
    private var initialPositionApplied = false
    private var followsLatest = true
    private var hasOlderHistory = false
    private var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
    private var olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
    private var isLoadingInitialHistory = false
    /// Row projection runs off the main actor. A retained session controller can
    /// already own exact scroll geometry while its newly mounted SwiftUI screen
    /// still has a temporary empty row array. Do not consume that geometry or
    /// validate its caches until the first displayable projection arrives
    /// after any initial history hydration.
    private var isPreparingInitialProjection = true
    private var scrollCommand = TranscriptScrollCommand()
    private var receivedSendAnimationToken: UInt64?
    private var pendingSendAnimationRequest: UserSendAnimationRequest?
    private var pendingSendAnimationRowKey: String?
    private var pendingSendSourceLayout: VirtualTranscriptLayout?
    private var sendAnimationSourceFrame: CGRect?
    private var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    private var onSendAnimationStarted:
        (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )?
    private var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)?
    private var activeSendAnimationRequest: UserSendAnimationRequest?
    private var activeSendSourceLayout: VirtualTranscriptLayout?
    private var hiddenSendAssistantRowKeys: Set<String> = []
    private var sendAnimationCompletion: TranscriptSendAnimationCompletion?
    private var presentationRole: TranscriptPresentationRole = .foreground
    private var reduceMotion = false

    private var positionApplicationDepth = 0
    private var isApplyingPosition: Bool {
        positionApplicationDepth > 0
    }

    private var lastDistanceFromBottom: CGFloat = 0
    private var lastBottomState: Bool?
    private var lastViewportSize: CGSize = .zero
    private var lastPrefetchOldestKey: String?
    private var isDetaching = false
    private var isExplicitUserScroll = false
    private var lastStableScrollState: SessionScrollState?
    private var appliedTopContentInset: CGFloat = 0

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?
    private var onOlderHistoryPresented: ((UInt64) -> Void)?
    private var onAttentionPresented: ((SessionAttentionTarget) -> Void)?
    private var presentationObservers: [NSObjectProtocol] = []

    private var isNativeScrollInteractionActive: Bool {
        isTracking || isDragging || isDecelerating || isExplicitUserScroll
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        canvasView.backgroundColor = .clear
        addSubview(canvasView)
        paginationLoadingIndicator.backgroundColor = .clear
        paginationLoadingIndicator.isHidden = true
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
        presentationObservers = [
            NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluatePresentedAttention() }
            },
            NotificationCenter.default.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluatePresentedAttention() }
            },
        ]
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        measurementCommitTask?.cancel()
        disclosureAnchorReleaseTask?.cancel()
        for observer in presentationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateTopContentInsetIfNeeded()
    }

    override func didMoveToWindow() {
        if window == nil, superview != nil {
            republishLastStableScrollState()
            isDetaching = true
        } else if window != nil {
            isDetaching = false
        }
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.evaluatePresentedAttention()
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

    func configure(
        rows newRows: [TranscriptVirtualRow],
        unreadAttentionTargets newUnreadAttentionTargets: [SessionAttentionTarget],
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
        sendAnimationSourceFrame newSendAnimationSourceFrame: CGRect?,
        presentationRole newPresentationRole: TranscriptPresentationRole,
        reduceMotion newReduceMotion: Bool,
        scrollIndicatorBottomInset newScrollIndicatorBottomInset: CGFloat,
        claimSendAnimation newClaimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        onSendAnimationStarted newOnSendAnimationStarted: (
            (
                UserSendAnimationRequest,
                TranscriptSendAnimationTarget
            ) -> Bool
        )?,
        onSendAnimationCompleted newOnSendAnimationCompleted:
            @escaping (
                UserSendAnimationRequest
            ) -> Void,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void,
        onOlderHistoryPresented: @escaping (UInt64) -> Void,
        onAttentionPresented: @escaping (SessionAttentionTarget) -> Void,
    ) {
        rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        self.onOlderHistoryPresented = onOlderHistoryPresented
        self.onAttentionPresented = onAttentionPresented
        unreadFinishedTargetByItemId = Dictionary(
            newUnreadAttentionTargets.compactMap { target in
                guard target.kind == .finished, let itemId = target.chatItemId else { return nil }
                return (itemId, target)
            },
            uniquingKeysWith: { current, next in
                current.sequence >= next.sequence ? current : next
            }
        )
        isPreparingInitialProjection = newIsPreparingInitialProjection
        isLoadingInitialHistory = newIsLoadingInitialHistory
        guard !newIsPreparingInitialProjection else {
            setNeedsLayout()
            return
        }
        hasOlderHistory = newHasOlderHistory
        let paginationHeaderReservationChanged = paginationHeaderLayout.reserveIfNeeded(
            hasOlderHistory: newHasOlderHistory,
            isPresented: newShowsOlderHistoryLoadingIndicator,
        )
        updatePaginationLoadingIndicator(
            isPresented: newShowsOlderHistoryLoadingIndicator
        )
        olderHistoryPresentationTarget = newOlderHistoryPresentationTarget
        reduceMotion = newReduceMotion
        updateBottomScrollIndicatorInsetIfNeeded(newScrollIndicatorBottomInset)
        sendAnimationSourceFrame = newSendAnimationSourceFrame
        claimSendAnimation = newClaimSendAnimation
        onSendAnimationStarted = newOnSendAnimationStarted
        onSendAnimationCompleted = newOnSendAnimationCompleted
        let becameForeground =
            presentationRole != .foreground
            && newPresentationRole == .foreground
        presentationRole = newPresentationRole

        if newSendAnimationRequest?.token != receivedSendAnimationToken {
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

        let prependedItemCount = reversePrependCount(from: rows, to: newRows)
        let rebuiltRows: Bool
        if prependedItemCount != nil, isNativeScrollInteractionActive,
            !layoutFingerprintChanged
        {
            deferredRowsDuringScroll = newRows
            rebuiltRows = false
        } else {
            deferredRowsDuringScroll = nil
            rebuiltRows = applyRows(
                newRows,
                layoutFingerprintChanged: layoutFingerprintChanged
            )
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
        if becameForeground {
            // The foreground transcript is now the sole viewport publisher.
            // First-send promotion is always pinned to the newest row, but use
            // the shared state when available so the handoff remains exact.
            if let initialState, initialPositionApplied {
                followsLatest = initialState.followMode.followsLatest
                setDistanceFromBottom(initialState.distanceFromBottom)
            }
            emitViewportSnapshot()
        }
        checkForHistoryPrefetch()
        acknowledgeOlderHistoryPresentationIfPossible()
        evaluatePresentedAttention()
        setNeedsLayout()
    }

    func prepareForDismantle() {
        republishLastStableScrollState()
        isDetaching = true
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        pendingMeasurements.removeAll(keepingCapacity: false)
        bottomJumpGate.cancel()
        deferredRowsDuringScroll = nil
        olderHistoryPresentationTarget = nil
        disclosureAnchorReleaseTask?.cancel()
        sendAnimationCompletion = nil
        activeSendAnimationRequest = nil
        activeSendSourceLayout = nil
        hiddenSendAssistantRowKeys.removeAll(keepingCapacity: false)
        for host in mountedHosts.values {
            host.removeFromSuperview()
            host.detachFromParent()
        }
        mountedHosts.removeAll(keepingCapacity: false)
        discardParkedHosts()
    }

    func discardParkedHosts() {
        for host in parkedHosts.values {
            host.detachFromParent()
        }
        parkedHosts.removeAll(keepingCapacity: false)
        parkedHostLRU.removeAll(keepingCapacity: false)
    }

    // MARK: - Rows and geometry

    @discardableResult
    private func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool,
    ) -> Bool {
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
                newRows: newRows,
            )
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            if layoutFingerprintChanged {
                discardParkedHosts()
            } else {
                evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
            }
            _ = activateMeasurementCacheIfNeeded()
            installExactSpacerMeasurements()
            // Row-set changes mount and recycle only the affected hosts below.
            // Preserve every other hosting tree so an insertion/removal cannot
            // blank the whole visible transcript for a SwiftUI commit.
            if layoutFingerprintChanged {
                refreshMountedRootViews()
            } else {
                refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            }
            rebuildDocumentGeometry()
            return true
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
            return false
        }
    }

    private func reversePrependCount(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
    ) -> Int? {
        guard !oldRows.isEmpty, newRows.count > oldRows.count else { return nil }
        let insertedCount = newRows.count - oldRows.count
        guard
            zip(oldRows, newRows.dropFirst(insertedCount)).allSatisfy({ old, new in
                old.id == new.id
            })
        else { return nil }
        return insertedCount
    }

    private func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
    ) {
        guard let oldActive = oldRows.first(where: { $0.id.isActiveRow }),
            let activeHeight = measurements[oldActive.layoutKey],
            !newRows.contains(where: { $0.layoutKey == oldActive.layoutKey })
        else { return }
        let oldKeys = Set(oldRows.map(\.layoutKey))
        let insertedSettledRows = newRows.filter {
            $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
        }
        guard insertedSettledRows.count == 1,
            let settledActive = insertedSettledRows.first,
            measurements[settledActive.layoutKey] == nil
        else { return }
        measurements.setProvisional(activeHeight, for: settledActive.layoutKey)
    }

    private func invalidateChangedMeasurements(
        previousRowsByKey: [String: TranscriptVirtualRow],
        newRows: [TranscriptVirtualRow],
    ) {
        for row in newRows {
            guard row.id.isCacheableSettledRow,
                let previous = previousRowsByKey[row.layoutKey],
                previous.measurementRevision != row.measurementRevision
            else { continue }
            let key = row.layoutKey
            measurements.markStale(key)
            pendingMeasurements.removeValue(forKey: key)
            settledRowHeightSnapshot.removeValue(forKey: key)
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey]?.removeValue(forKey: key)
            }
            if let host = mountedHosts[key] {
                host.resetReportedContentHeight()
                host.requestContentMeasurement()
            }
        }
    }

    private func installExactSpacerMeasurements() {
        for row in rows {
            if case let .bottomSpacer(height) = row.content {
                measurements.setExact(height, for: row.layoutKey)
            }
        }
    }

    private var effectiveRowWidth: CGFloat {
        let availableWidth = max(1, bounds.width - Self.horizontalPadding * 2)
        return min(Self.maxRowWidth, availableWidth)
    }

    @discardableResult
    private func activateMeasurementCacheIfNeeded() -> Bool {
        guard bounds.width > 0 else { return false }
        let key = SessionMeasurementCacheKey(
            rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
            layoutFingerprint: layoutFingerprint,
        )
        guard key != activeMeasurementCacheKey else { return false }

        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        pendingMeasurements.removeAll(keepingCapacity: true)
        activeMeasurementCacheKey = key
        measurementCacheLRU.removeAll { $0 == key }
        measurementCacheLRU.append(key)
        while measurementCacheLRU.count > Self.maxMeasurementCacheCount {
            let evicted = measurementCacheLRU.removeFirst()
            measurementCaches.removeValue(forKey: evicted)
        }

        let provisionalMountedHeights = Dictionary(
            uniqueKeysWithValues: mountedHosts.keys.compactMap { mountedKey in
                measurements[mountedKey].map { (mountedKey, $0) }
            },
        )
        measurements.removeAll(keepingCapacity: true)
        let cached = measurementCaches[key] ?? [:]
        var valid: [String: SessionMeasuredRow] = [:]
        valid.reserveCapacity(cached.count)
        for row in rows {
            guard row.id.isCacheableSettledRow,
                let measurement = cached[row.layoutKey],
                measurement.revision == row.measurementRevision,
                measurement.height > 0
            else { continue }
            valid[row.layoutKey] = measurement
            measurements.setExact(measurement.height, for: row.layoutKey)
        }
        settledRowHeightSnapshot = valid
        measurementCaches[key] = valid
        installExactSpacerMeasurements()
        for (mountedKey, height) in provisionalMountedHeights
        where measurements[mountedKey] == nil {
            measurements.setProvisional(height, for: mountedKey)
        }

        if let restore = pendingInitialState?.virtualTranscript,
            restore.measurementCacheKey == key
        {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey], measurements[rowKey] == nil else { continue }
                if row.id.isCacheableSettledRow {
                    guard let settled = restore.settledRowsByKey[rowKey],
                        settled.revision == row.measurementRevision
                    else { continue }
                    measurements.setExact(height, for: rowKey)
                    let measurement = SessionMeasuredRow(
                        height: height,
                        revision: settled.revision,
                    )
                    settledRowHeightSnapshot[rowKey] = measurement
                    measurementCaches[key, default: [:]][rowKey] = measurement
                } else {
                    measurements.setProvisional(height, for: rowKey)
                }
            }
        }
        return true
    }

    private func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
        let previousLayout = virtualLayout
        let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
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
                viewportHeight: viewportHeight,
                overscanCount: 0,
            )
            visibleAnchorKey =
                visibleRange.compactMap { index -> String? in
                    guard previousLayout.keys.indices.contains(index) else { return nil }
                    let key = previousLayout.keys[index]
                    return measurements[key] == nil ? nil : key
                }.first
                ?? visibleRange.first.flatMap { index in
                    previousLayout.keys.indices.contains(index)
                        ? previousLayout.keys[index]
                        : nil
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
                        .init(key: $0.layoutKey, estimatedHeight: $0.estimatedHeight)
                    },
                    measuredHeights: measurements.heightsByKey,
                    spacing: Self.rowSpacing,
                )
            initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
                virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
            }

            let documentSize = CGSize(
                width: max(1, bounds.width),
                height: paginationHeaderLayout.documentHeight(
                    topPadding: Self.topPadding,
                    rowsHeight: virtualLayout.totalHeight
                ),
            )
            contentSize = documentSize
            canvasView.frame = CGRect(origin: .zero, size: documentSize)
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
                            previousDistanceFromBottom: distanceToPreserve,
                        )
                    }
                let resolvedDistance = anchoredDistance ?? distanceToPreserve
                if lockedRestoreDistance != nil {
                    lockedRestoreDistance = resolvedDistance
                }
                setDistanceFromBottom(resolvedDistance)
            }
            lastDistanceFromBottom = currentDistanceFromBottom()
        }
        updateMountedRows(rangeOverride: initialRestoreRange)
        updateInitialPresentationReadiness()
    }

    private func incrementallyUpdatedLayout(
        changedHeights: [String: CGFloat]?,
    ) -> VirtualTranscriptLayout? {
        guard let changedHeights, !changedHeights.isEmpty,
            !virtualLayout.isEmpty,
            virtualLayout.keys.count == rows.count
        else { return nil }
        var layout = virtualLayout
        for (key, height) in changedHeights {
            guard let updated = layout.updatingHeight(forKey: key, to: height) else {
                return nil
            }
            layout = updated
        }
        return layout
    }

    // MARK: - Viewport

    private var viewportHeight: CGFloat {
        max(0, bounds.height)
    }

    private var viewportGeometry: VirtualTranscriptViewport {
        VirtualTranscriptViewport(
            contentHeight: paginationHeaderLayout.documentHeight(
                topPadding: Self.topPadding,
                rowsHeight: virtualLayout.totalHeight
            ),
            viewportHeight: viewportHeight,
            topInset: appliedTopContentInset,
        )
    }

    private func currentDistanceFromBottom() -> CGFloat {
        viewportGeometry.distanceFromBottom(offsetY: contentOffset.y)
    }

    private func setDistanceFromBottom(
        _ distance: CGFloat,
        synchronizesWithActiveLayoutAnimation: Bool = false
    ) {
        setViewportTop(
            viewportGeometry.offsetY(distanceFromBottom: distance),
            synchronizesWithActiveLayoutAnimation: synchronizesWithActiveLayoutAnimation
        )
    }

    private func setViewportTop(
        _ requestedTop: CGFloat,
        synchronizesWithActiveLayoutAnimation: Bool = false
    ) {
        let top = viewportGeometry.boundedOffsetY(requestedTop)
        guard abs(contentOffset.y - top) > 0.25 else { return }
        let mutation = {
            self.setContentOffset(CGPoint(x: 0, y: top), animated: false)
        }
        if synchronizesWithActiveLayoutAnimation {
            applyPositionMutation(mutation)
        } else {
            applyPositionTransaction(mutation)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
    }

    private func applyPositionMutation(_ body: () -> Void) {
        positionApplicationDepth += 1
        defer { positionApplicationDepth -= 1 }
        body()
    }

    private func applyPositionTransaction(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation {
            applyPositionMutation(body)
        }
        CATransaction.commit()
    }

    private func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, viewportHeight > 0 else { return }
        let shouldPublishInitialPosition =
            lastStableScrollState == nil
            || (pendingInitialState?.isAtBottom == true && followsLatest)
        let restoredRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
            virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
        }
        updateMountedRows(rangeOverride: restoredRange)

        if let state = pendingInitialState, !state.isAtBottom {
            if state.distanceFromBottom > viewportGeometry.maximumDistanceFromBottom + 0.5,
                hasOlderHistory
            {
                setViewportTop(viewportGeometry.minimumOffsetY)
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
        lastDistanceFromBottom = currentDistanceFromBottom()
        updateMountedRows(rangeOverride: restoredRange)
        if shouldPublishInitialPosition { emitViewportSnapshot() }
    }

    private func updateTopContentInsetIfNeeded() {
        let topInset = max(0, safeAreaInsets.top)
        guard abs(appliedTopContentInset - topInset) > 0.5 else { return }
        let preservedDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
        appliedTopContentInset = topInset
        applyPositionTransaction {
            var inset = contentInset
            inset.top = topInset
            contentInset = inset
            var indicatorInset = verticalScrollIndicatorInsets
            indicatorInset.top = topInset
            verticalScrollIndicatorInsets = indicatorInset
        }
        if let preservedDistance, !isNativeScrollInteractionActive {
            setDistanceFromBottom(preservedDistance)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
    }

    /// The composer floats over the scroll view, so its height must shorten
    /// only the indicator track. Transcript content keeps its existing bottom
    /// spacer and scroll geometry; this is a visual affordance, not an inset
    /// that participates in positioning or restoration.
    private func updateBottomScrollIndicatorInsetIfNeeded(_ rawInset: CGFloat) {
        let bottomInset = max(0, rawInset)
        guard abs(verticalScrollIndicatorInsets.bottom - bottomInset) > 0.5 else { return }
        var indicatorInset = verticalScrollIndicatorInsets
        indicatorInset.bottom = bottomInset
        verticalScrollIndicatorInsets = indicatorInset
    }

    private func scrollToBottom() {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        measurementCommitGate.interactionDidEnd()
        commitPendingMeasurements()
        bottomJumpGate.begin()
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
        resolveBottomJumpIfPossible()
    }

    // MARK: - Native scrolling

    func scrollViewWillBeginDragging(_: UIScrollView) {
        measurementCommitGate.draggingDidBegin()
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isExplicitUserScroll = false
        // Touching down interrupts UIKit's deceleration. Flush measurements
        // retained from that momentum phase before the new drag advances.
        commitPendingMeasurements()
    }

    func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
        cancelDisclosureViewportAnchor()
        bottomJumpGate.cancel()
        lockedRestoreDistance = nil
        isExplicitUserScroll = true
        return false
    }

    func scrollViewDidScroll(_: UIScrollView) {
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance
        if initialPositionApplied {
            updateMountedRows()
        }
        evaluatePresentedAttention()

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let isUserMovement =
            isTracking || isDragging || isDecelerating
            || isExplicitUserScroll
        if !isApplyingPosition, isUserMovement,
            distance > previousDistance + 0.5, followsLatest
        {
            followsLatest = false
            onFollowStateChange?(false)
        } else if !isApplyingPosition, isUserMovement, atBottom, !followsLatest {
            followsLatest = true
            onFollowStateChange?(true)
        }
        if !isApplyingPosition, isUserMovement {
            lockedRestoreDistance = nil
            emitViewportSnapshot()
        }
        checkForHistoryPrefetch()
    }

    func scrollViewDidEndDragging(
        _: UIScrollView,
        willDecelerate decelerate: Bool,
    ) {
        measurementCommitGate.draggingDidEnd(willDecelerate: decelerate)
        if !decelerate { finishNativeScrollInteraction() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }

    private func finishNativeScrollInteraction() {
        if let deferredRowsDuringScroll {
            self.deferredRowsDuringScroll = nil
            applyRows(deferredRowsDuringScroll, layoutFingerprintChanged: false)
        }
        commitPendingMeasurements()
        updateMountedRows()
        startPendingSendAnimationIfPossible()
        emitViewportSnapshot()
        checkForHistoryPrefetch()
        acknowledgeOlderHistoryPresentationIfPossible()
    }

    /// The model's response can arrive while UIKit is still dragging or
    /// decelerating. In that case `configure` parks the prepend so native
    /// momentum is uninterrupted. Acknowledge only after the matching oldest
    /// row is part of the authoritative document geometry.
    private func acknowledgeOlderHistoryPresentationIfPossible() {
        guard deferredRowsDuringScroll == nil,
            let target = olderHistoryPresentationTarget,
            rows.first?.layoutKey == target.oldestRowKey
        else { return }
        olderHistoryPresentationTarget = nil
        onOlderHistoryPresented?(target.token)
    }

    // MARK: - Virtual row mounting

    private func plannedMountedRange() -> Range<Int> {
        let distance = currentDistanceFromBottom()
        if !initialPresentationGate.isReady {
            let runway = viewportHeight * Self.initialRunwayViewportCount
            return virtualLayout.visibleRange(
                distanceFromBottom: distance,
                viewportHeight: viewportHeight,
                runwayBefore: runway,
                runwayAfter: runway,
            )
        }
        let visibleRange = virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: viewportHeight,
            overscanCount: 0,
        )
        let overscannedRange = virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: viewportHeight,
            overscanCount: Self.overscanCount,
        )
        let planIndices = overscannedRange.filter { index in
            guard rows.indices.contains(index) else { return false }
            return rows[index].id.isPlanDocument
        }
        return VirtualTranscriptLayout.overscanRange(
            visibleRange: visibleRange,
            overscannedRange: overscannedRange,
            stoppingAt: planIndices,
        )
    }

    private func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || viewportHeight > 0,
            let hostingParent
        else { return }
        let targetRange: Range<Int>
        if let rangeOverride {
            targetRange = rangeOverride
        } else {
            targetRange = plannedMountedRange()
        }

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
            park(host, for: key)
        }

        for index in range {
            guard virtualLayout.keys.indices.contains(index) else { continue }
            let key = virtualLayout.keys[index]
            guard mountedHosts[key] == nil, let row = rowByKey[key] else { continue }
            let host = takeParkedHost(for: key) ?? TranscriptRowHost(parent: hostingParent)
            host.onMeasuredHeight = { [weak self] measurement in
                self?.recordMeasuredHeight(measurement)
            }
            canvasView.addSubview(host)
            mountedHosts[key] = host
            position(host: host, at: index)
            host.syncContentWidth()
            host.install(
                row: row,
                rootView: measuredRootView(for: row),
                force: host.representedRow == nil,
            )
        }
        synchronizeSendAssistantVisibility()
    }

    private func park(_ host: TranscriptRowHost, for key: String) {
        guard rowByKey[key] != nil else {
            host.detachFromParent()
            return
        }
        parkedHosts[key]?.detachFromParent()
        parkedHosts[key] = host
        parkedHostLRU.removeAll { $0 == key }
        parkedHostLRU.append(key)
        while parkedHostLRU.count > Self.maxParkedHostCount {
            let evicted = parkedHostLRU.removeFirst()
            parkedHosts.removeValue(forKey: evicted)?.detachFromParent()
        }
    }

    private func takeParkedHost(for key: String) -> TranscriptRowHost? {
        guard let host = parkedHosts.removeValue(forKey: key) else { return nil }
        parkedHostLRU.removeAll { $0 == key }
        return host
    }

    private func evictChangedParkedHosts(
        previousRowsByKey: [String: TranscriptVirtualRow],
    ) {
        let staleKeys = parkedHostLRU.filter { key in
            guard let row = rowByKey[key] else { return true }
            return previousRowsByKey[key]?.content != row.content
                || previousRowsByKey[key]?.measurementRevision != row.measurementRevision
        }
        for key in staleKeys {
            parkedHosts.removeValue(forKey: key)?.detachFromParent()
        }
        parkedHostLRU.removeAll { staleKeys.contains($0) }
    }

    private func refreshMountedRootViews() {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key] else { continue }
            host.install(row: row, rootView: measuredRootView(for: row), force: true)
        }
    }

    private func refreshChangedMountedRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow],
    ) {
        for (key, host) in mountedHosts {
            guard let row = rowByKey[key], let previous = previousRowsByKey[key],
                previous.content != row.content
                    || previous.measurementRevision != row.measurementRevision
            else { continue }
            host.install(row: row, rootView: measuredRootView(for: row), force: true)
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key),
        )
    }

    private func attachmentGeometryReadinessDidChange(_ ready: Bool, for key: String) {
        guard let host = mountedHosts[key], host.setAttachmentGeometryReady(ready) else {
            return
        }
        updateInitialPresentationReadiness()
    }

    private func positionMountedRows() {
        for (key, host) in mountedHosts {
            guard let index = virtualLayout.indexByKey[key] else { continue }
            position(host: host, at: index)
        }
    }

    private func position(host: TranscriptRowHost, at index: Int) {
        guard virtualLayout.heights.indices.contains(index) else { return }
        let viewportWidth = max(1, bounds.width)
        let availableWidth = max(1, viewportWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (viewportWidth - rowWidth) / 2)
        let nextFrame = CGRect(
            x: rowX,
            y: paginationHeaderLayout.rowOrigin(
                topPadding: Self.topPadding,
                rowOffset: virtualLayout.topOffsets[index]
            ),
            width: rowWidth,
            height: virtualLayout.heights[index],
        )
        if host.frame != nextFrame {
            host.frame = nextFrame
        }
        host.syncContentWidth()
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
        paginationLoadingIndicator.sizeToFit()
        let size = paginationLoadingIndicator.bounds.size
        paginationLoadingIndicator.frame = CGRect(
            x: (max(1, bounds.width) - size.width) / 2,
            y: Self.topPadding
                + (paginationHeaderLayout.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Measurement

    private func recordMeasuredHeight(_ rawMeasurement: TranscriptRowMeasurement) {
        let scale = TranscriptPixelGeometry.displayScale(for: self)
        let measurement = TranscriptRowMeasurement(
            key: rawMeasurement.key,
            revision: rawMeasurement.revision,
            rowWidthHalfPoints: rawMeasurement.rowWidthHalfPoints,
            height: max(
                1,
                TranscriptPixelGeometry.ceil(rawMeasurement.height, scale: scale),
            ),
        )
        guard accepts(measurement) else { return }
        let needsCommit =
            pendingMeasurements[measurement.key].map {
                $0.revision != measurement.revision
                    || $0.rowWidthHalfPoints != measurement.rowWidthHalfPoints
                    || TranscriptPixelGeometry.differs(
                        $0.height,
                        measurement.height,
                        scale: scale,
                    )
            } ?? measurements.needsCommit(measurement.height, for: measurement.key)
        guard needsCommit else {
            // Cached settled rows can report the exact height already in the
            // ledger. The host has still completed a fresh SwiftUI layout, so
            // wake presentation gates even though no geometry commit follows.
            updateInitialPresentationReadiness()
            resolveBottomJumpIfPossible()
            startPendingSendAnimationIfPossible()
            evaluatePresentedAttention()
            return
        }
        pendingMeasurements[measurement.key] = measurement
        // Active output needs its latest geometry without an extra frame.
        // Ordinary mounted rows batch into one document snapshot, matching
        // the macOS virtualizer and avoiding redundant anchor corrections.
        guard measurementCommitGate.allowsGeometryCommit else { return }
        if rowByKey[measurement.key]?.id.isActiveRow == true {
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
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        // Mounted hosts remain clipped to the currently committed ledger
        // while UIKit owns post-lift momentum. This keeps rows non-overlapping
        // without replacing the deceleration animation via contentOffset.
        guard measurementCommitGate.allowsGeometryCommit else { return }
        let pending = pendingMeasurements
        pendingMeasurements.removeAll(keepingCapacity: true)
        var committedHeights: [String: CGFloat] = [:]
        for (key, measurement) in pending {
            guard accepts(measurement),
                measurements.needsCommit(measurement.height, for: key)
            else { continue }
            if storeMeasuredHeight(measurement.height, for: key) {
                committedHeights[key] = measurement.height
            }
        }
        if !committedHeights.isEmpty {
            rebuildDocumentGeometry(changedHeights: committedHeights)
        }
        updateInitialPresentationReadiness()
        resolveBottomJumpIfPossible()
        startPendingSendAnimationIfPossible()
        evaluatePresentedAttention()
    }

    /// An explicit bottom jump spans more than one layout transaction. Keep
    /// pinning every height correction to distance zero until the complete
    /// destination window is mounted and exact; only then return to ordinary
    /// row anchoring.
    private func resolveBottomJumpIfPossible() {
        guard bottomJumpGate.isActive,
            initialPositionApplied,
            viewportHeight > 0
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
            hasPendingMeasurements: !pendingMeasurements.isEmpty
        )
    }

    private func updateInitialPresentationReadiness() {
        guard !initialPresentationGate.isReady,
            !isDetaching,
            initialPositionApplied,
            viewportHeight > 0
        else { return }

        let requiredKeys = Set(
            plannedMountedRange().compactMap { index in
                virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
            })
        let mountedKeys = Set(mountedHosts.keys)
        guard requiredKeys.isSubset(of: mountedKeys) else {
            // Resolving estimates can change which rows intersect the initial
            // viewport. Mount that new window and wait for its measurements
            // instead of revealing an intermediate geometry snapshot.
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
            )
        else { return }

        applyPositionTransaction {
            canvasView.alpha = 1
            canvasView.accessibilityElementsHidden = false
        }
        isScrollEnabled = true
        evaluatePresentedAttention()
    }

    /// Emits a receipt only from the sole foreground transcript when a
    /// completed assistant row has committed and intersects the real viewport.
    private func evaluatePresentedAttention() {
        let candidate: SessionAttentionTarget? = {
            guard initialPresentationGate.isReady,
                !isDetaching,
                presentationRole == .foreground,
                canvasView.alpha > 0,
                UIApplication.shared.applicationState == .active,
                let window,
                window.windowScene?.activationState == .foregroundActive,
                isActuallyVisible,
                !unreadFinishedTargetByItemId.isEmpty
            else { return nil }

            let viewport = convert(bounds, to: canvasView)
            guard viewport.width > 0, viewport.height > 0 else { return nil }
            let range = virtualLayout.visibleRange(
                distanceFromBottom: currentDistanceFromBottom(),
                viewportHeight: viewportHeight,
                overscanCount: 0
            )
            return range.compactMap { index -> SessionAttentionTarget? in
                guard rows.indices.contains(index),
                    let itemId = rows[index].finishedResponseItemId,
                    let target = unreadFinishedTargetByItemId[itemId],
                    let host = mountedHosts[rows[index].layoutKey],
                    !host.isHidden,
                    host.alpha > 0,
                    host.isPresentationReady,
                    host.frame.intersects(viewport)
                else { return nil }
                return target
            }.max(by: { $0.sequence < $1.sequence })
        }()

        guard candidate != lastPresentedAttentionTarget else { return }
        lastPresentedAttentionTarget = candidate
        if let candidate {
            onAttentionPresented?(candidate)
        }
    }

    private var isActuallyVisible: Bool {
        var view: UIView? = self
        while let current = view {
            if current.isHidden || current.alpha <= 0.01 { return false }
            view = current.superview
        }
        return true
    }

    private func accepts(_ measurement: TranscriptRowMeasurement) -> Bool {
        guard let row = rowByKey[measurement.key],
            row.measurementRevision == measurement.revision,
            measurement.rowWidthHalfPoints
                == Int((effectiveRowWidth * 2).rounded())
        else { return false }
        return true
    }

    @discardableResult
    private func storeMeasuredHeight(_ height: CGFloat, for key: String) -> Bool {
        let heightChanged = measurements.commit(height, for: key)
        if let row = rowByKey[key], row.id.isCacheableSettledRow {
            let measurement = SessionMeasuredRow(
                height: height,
                revision: row.measurementRevision,
            )
            settledRowHeightSnapshot[key] = measurement
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey, default: [:]][key] = measurement
            }
        }
        return heightChanged
    }

    // MARK: - Disclosure and send presentation

    private func performAnchoredDisclosureChange(
        in rowKey: String,
        change: @escaping () -> Void,
    ) {
        guard initialPositionApplied,
            virtualLayout.indexByKey[rowKey] != nil
        else {
            change()
            return
        }
        bottomJumpGate.cancel()
        disclosureAnchorReleaseTask?.cancel()
        let anchor = DisclosureViewportAnchor(
            id: UUID(),
            viewportTop: contentOffset.y,
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

    private func startPendingSendAnimationIfPossible() {
        guard let request = pendingSendAnimationRequest,
            let rowKey = pendingSendAnimationRowKey
        else { return }
        guard initialPositionApplied, bounds.width > 0, bounds.height > 0,
            let host = mountedHosts[rowKey], host.isPresentationReady,
            sendHistoryDestinationIsReady(
                sourceLayout: pendingSendSourceLayout,
                rowKey: rowKey
            )
        else { return }

        // Prewarmed destinations do not own animation consumption, but their
        // full-screen layout is the authoritative endpoint for New Chat's
        // flight layer. Report it before the foreground-only claim gate.
        let usesExternalFlight: Bool
        if let onSendAnimationStarted,
            let target = sendAnimationTarget(in: host, rowKey: rowKey)
        {
            usesExternalFlight = onSendAnimationStarted(request, target)
        } else {
            usesExternalFlight = false
        }
        guard presentationRole == .foreground,
            let claimSendAnimation
        else { return }

        func claimAndClear() -> Bool {
            let claimed = claimSendAnimation(request)
            pendingSendAnimationRequest = nil
            pendingSendAnimationRowKey = nil
            pendingSendSourceLayout = nil
            return claimed
        }

        func claimAndCompleteWithoutAnimation() {
            let claimed = claimAndClear()
            finishSendPresentation()
            guard claimed else { return }
            onSendAnimationCompleted?(request)
        }

        guard !reduceMotion else {
            claimAndCompleteWithoutAnimation()
            return
        }
        let sourceLayout = pendingSendSourceLayout
        let bottomSpacerHeight =
            rows.last { $0.id == .bottomSpacer }.flatMap { row in
                if case let .bottomSpacer(height) = row.content { height } else { nil }
            } ?? 0
        let fallbackSourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
        // Composer reports its editor frame in the global SwiftUI coordinate
        // space, which maps to window coordinates on iOS. Converting through
        // the canvas gives the row animation the real launch position rather
        // than an estimated offset above the bottom spacer.
        let sourceY =
            sendAnimationSourceFrame.map { sourceFrame in
                canvasView.convert(
                    CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
                    from: nil
                ).y
            } ?? fallbackSourceY
        guard
            let plan = TranscriptSendAnimationMetrics.plan(
                sourceY: sourceY,
                targetY: host.frame.minY
            )
        else {
            claimAndCompleteWithoutAnimation()
            return
        }
        guard claimAndClear() else {
            finishSendPresentation()
            return
        }

        host.layer.removeAnimation(forKey: "codevisor.user-send")
        beginSendPresentation(request: request, sourceLayout: sourceLayout)
        if usesExternalFlight {
            host.layer.opacity = 0
        }
        let group = TranscriptSendAnimationMetrics.layerAnimation(
            plan: plan,
            fadesIn: !usesExternalFlight
        )
        activeSendAnimationRequest = request
        let completion = TranscriptSendAnimationCompletion { [weak self] _ in
            guard let self,
                self.activeSendAnimationRequest?.token == request.token
            else { return }
            host.layer.opacity = 1
            self.finishSendPresentation()
            self.onSendAnimationCompleted?(request)
        }
        sendAnimationCompletion = completion
        group.delegate = completion
        host.layer.add(group, forKey: "codevisor.user-send")
    }

    private func beginSendPresentation(
        request: UserSendAnimationRequest,
        sourceLayout: VirtualTranscriptLayout?
    ) {
        finishSendPresentation()
        activeSendAnimationRequest = request
        activeSendSourceLayout = sourceLayout

        if let sourceLayout {
            for (key, host) in mountedHosts {
                guard
                    let translation = TranscriptSendHistoryTransition.translationY(
                        forKey: key,
                        from: sourceLayout,
                        to: virtualLayout
                    ),
                    translation > 1
                else { continue }
                host.layer.removeAnimation(forKey: "codevisor.send-history-shift")
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
                host.layer.add(movement, forKey: "codevisor.send-history-shift")
            }
        }
        synchronizeSendAssistantVisibility()
    }

    private func synchronizeSendAssistantVisibility() {
        guard presentationRole == .foreground else { return }
        let sourceLayout = activeSendSourceLayout ?? pendingSendSourceLayout
        guard activeSendAnimationRequest != nil || pendingSendAnimationRequest != nil else { return }
        for (key, host) in mountedHosts {
            guard rowByKey[key]?.id.isActiveRow == true,
                sourceLayout?.indexByKey[key] == nil
            else { continue }
            host.layer.opacity = 0
            hiddenSendAssistantRowKeys.insert(key)
        }
    }

    private func finishSendPresentation() {
        for key in hiddenSendAssistantRowKeys {
            mountedHosts[key]?.layer.opacity = 1
        }
        hiddenSendAssistantRowKeys.removeAll(keepingCapacity: true)
        activeSendAnimationRequest = nil
        activeSendSourceLayout = nil
        sendAnimationCompletion = nil
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

    private func sendAnimationTarget(
        in host: UIView,
        rowKey: String
    ) -> TranscriptSendAnimationTarget? {
        guard rowByKey[rowKey]?.isUserMessage == true,
            !host.bounds.isEmpty,
            let snapshot = host.snapshotView(afterScreenUpdates: false)
        else { return nil }
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        snapshot.backgroundColor = .clear
        return TranscriptSendAnimationTarget(
            rowFrame: host.convert(host.bounds, to: nil),
            rowSnapshot: snapshot
        )
    }

    // MARK: - State and pagination

    private func checkForHistoryPrefetch(force: Bool = false) {
        guard presentationRole == .foreground else { return }
        guard !rows.isEmpty else { return }
        let distanceFromTop = viewportGeometry.distanceFromTop(offsetY: contentOffset.y)
        let threshold = max(600, viewportHeight * 1.5)
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

    private func emitViewportSnapshot() {
        guard presentationRole == .foreground,
            !isDetaching, initialPositionConfigured, viewportHeight > 0
        else { return }
        let distance = currentDistanceFromBottom()
        publishBottomState(distance <= Self.atBottomThreshold)
        let state = SessionScrollState(
            distanceFromBottom: distance,
            measurementCaches: measurementCaches,
            measurementCacheLRU: measurementCacheLRU,
            virtualTranscript: currentVirtualRestoreState(),
            followMode: followsLatest ? .followingLatest : .staticPosition,
        )
        lastStableScrollState = state
        onViewportChange?(state)
    }

    private func republishLastStableScrollState() {
        guard presentationRole == .foreground else { return }
        guard var state = lastStableScrollState else { return }
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
                count: last - first + 1,
            )
        }
        return SessionVirtualTranscriptRestoreState(
            measurementCacheKey: activeMeasurementCacheKey,
            rowHeightsByKey: measurements.heightsByKey,
            settledRowsByKey: settledRowHeightSnapshot,
            renderedWindow: renderedWindow,
        )
    }

    private func publishBottomState(_ isAtBottom: Bool) {
        guard presentationRole == .foreground else { return }
        guard lastBottomState != isAtBottom else { return }
        lastBottomState = isAtBottom
        onBottomStateChange?(isAtBottom)
    }
}
