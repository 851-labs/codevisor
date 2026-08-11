import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import UIKit

/// Stable rows consumed by the native iOS transcript virtualizer. Settled
/// content is immutable; the active row observes the controller from its own
/// hosting subtree so streaming never diffs the complete conversation.
struct TranscriptVirtualRow: Identifiable, Equatable {
    enum ID: Hashable {
        case message(UUID)
        case assistantPlanning(UUID)
        case plan(UUID)
        case assistantResult(UUID)
        case active
        case setup
        case backgroundTask
        case updateGate
        case connecting
        case serverWait
        case error
        case statusError
        case bottomSpacer

        var layoutKey: String {
            switch self {
            case let .message(id): "message:\(id.uuidString)"
            case let .assistantPlanning(id): "message:\(id.uuidString):planning"
            case let .plan(id): "message:\(id.uuidString):plan"
            case let .assistantResult(id): "message:\(id.uuidString):result"
            case .active: "special:active"
            case .setup: "special:setup"
            case .backgroundTask: "special:background"
            case .updateGate: "special:update-gate"
            case .connecting: "special:connecting"
            case .serverWait: "special:server-wait"
            case .error: "special:error"
            case .statusError: "special:status-error"
            case .bottomSpacer: "special:bottom-spacer"
            }
        }

        var isCacheableSettledRow: Bool {
            switch self {
            case .message, .assistantPlanning, .plan, .assistantResult: true
            case .active, .setup, .backgroundTask, .updateGate, .connecting, .serverWait,
                 .error, .statusError, .bottomSpacer: false
            }
        }

        var isPlanDocument: Bool {
            if case .plan = self { true } else { false }
        }
    }

    enum Content: Equatable {
        case message(ConversationItem, waitingOnBackgroundTask: String?)
        case assistantPlanning(AssistantMessage)
        case planDocument(String)
        case assistantResult(AssistantMessage, waitingOnBackgroundTask: String?)
        case active
        case setup([SessionSetupPhase])
        case optimistic(UserMessage, showsStartingAgent: Bool)
        case backgroundTask(String)
        case updateGate(String)
        case connecting(String)
        case serverWait(String)
        case error(String)
        case bottomSpacer(CGFloat)
    }

    let id: ID
    let content: Content
    let estimatedHeight: CGFloat
    let measurementRevision: Int
    let layoutKey: String

    var isUserMessage: Bool {
        switch content {
        case let .message(item, waitingOnBackgroundTask: _):
            if case .user = item { return true }
            return false
        case .optimistic:
            return true
        default:
            return false
        }
    }

    init(
        id: ID,
        content: Content,
        estimatedHeight: CGFloat,
        measurementRevision: Int = 0
    ) {
        self.id = id
        self.content = content
        self.estimatedHeight = estimatedHeight
        self.measurementRevision = measurementRevision
        self.layoutKey = id.layoutKey
    }
}

struct TranscriptScrollCommand: Equatable {
    var token = 0
}

/// SwiftUI boundary around the UIKit virtualizer. All high-frequency geometry
/// and row mounting stays in UIKit; SwiftUI receives only viewport snapshots
/// and boundary transitions.
struct NativeTranscriptView: UIViewRepresentable {
    let rows: [TranscriptVirtualRow]
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let sendAnimationRequest: UserSendAnimationRequest?
    let reduceMotion: Bool
    let claimSendAnimation: @MainActor (UserSendAnimationRequest) -> Bool
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void

    func makeUIView(context: Context) -> VirtualizedTranscriptScrollView {
        let view = VirtualizedTranscriptScrollView()
        configure(view)
        return view
    }

    func updateUIView(_ view: VirtualizedTranscriptScrollView, context: Context) {
        configure(view)
    }

    static func dismantleUIView(
        _ view: VirtualizedTranscriptScrollView,
        coordinator: Void
    ) {
        view.prepareForDismantle()
    }

    private func configure(_ view: VirtualizedTranscriptScrollView) {
        view.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop
        )
    }
}

@MainActor
private final class TranscriptContentHostingController: UIHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureAndReportHeight()
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    func invalidateContentSize() {
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        guard pendingMeasurementTask == nil else { return }
        pendingMeasurementTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingMeasurementTask = nil
            self.view.layoutIfNeeded()
            self.measureAndReportHeight()
        }
    }

    func resetReportedHeight() {
        lastReportedHeight = 0
    }

    private func measureAndReportHeight() {
        let width = view.bounds.width
        guard width > 1 else { return }
        let height = max(
            1,
            sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                .height.rounded(.up)
        )
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }
}

/// A mounted row owns its natural SwiftUI height. The virtualizer supplies
/// only its width and top coordinate, then consumes measured-height changes.
@MainActor
private final class TranscriptRowHost: UIView {
    private let contentController = TranscriptContentHostingController(
        rootView: AnyView(EmptyView())
    )
    private var contentView: UIView { contentController.view }
    private weak var installedParent: UIViewController?
    private var lastContentWidth: CGFloat = 0
    var onHeightChange: ((CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false
        addSubview(contentView)
        contentController.sizingOptions = [.intrinsicContentSize]
        contentController.onLaidOutHeightChange = { [weak self] height in
            self?.contentHeightDidChange(height)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(1, bounds.width)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: max(1, bounds.height))
        if abs(lastContentWidth - width) > 0.5 {
            lastContentWidth = width
            contentController.invalidateContentSize()
        }
    }

    var rootView: AnyView {
        get { contentController.rootView }
        set {
            contentController.rootView = newValue
            contentController.invalidateContentSize()
        }
    }

    func installHostingController(in parent: UIViewController?) {
        guard let parent, installedParent !== parent else { return }
        detachHostingController()
        parent.addChild(contentController)
        contentController.didMove(toParent: parent)
        installedParent = parent
    }

    func detachHostingController() {
        guard contentController.parent != nil else {
            installedParent = nil
            return
        }
        contentController.willMove(toParent: nil)
        contentController.removeFromParent()
        installedParent = nil
    }

    func prepareForMountedRow() {
        layer.removeAnimation(forKey: "codevisor.user-send")
        contentController.resetReportedHeight()
    }

    func requestContentMeasurement() {
        contentController.invalidateContentSize()
    }

    func resetReportedContentHeight() {
        contentController.resetReportedHeight()
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        if abs(frame.height - height) > 0.5 {
            var nextFrame = frame
            nextFrame.size.height = height
            frame = nextFrame
        }
        if abs(contentView.frame.height - height) > 0.5 {
            var nextFrame = contentView.frame
            nextFrame.size.height = height
            contentView.frame = nextFrame
        }
        onHeightChange?(height)
    }
}

/// One authoritative UIKit owner for viewport position, virtual row mounting,
/// height compensation, and the user-send presentation animation.
@MainActor
final class VirtualizedTranscriptScrollView: UIScrollView, UIScrollViewDelegate {
    private static let rowSpacing: CGFloat = 20
    private static let topPadding: CGFloat = 12
    private static let horizontalPadding: CGFloat = 16
    private static let maxRowWidth: CGFloat = 832
    private static let overscanCount = 2
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3
    private static let sendAnimationDuration: CFTimeInterval = 0.46

    private let transcriptDocumentView = UIView()
    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var virtualLayout = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: rowSpacing
    )
    private var measurements = TranscriptMeasurementLedger()
    private var settledRowHeightSnapshot: [String: SessionMeasuredRow] = [:]
    private var measurementCaches: [
        SessionMeasurementCacheKey: [String: SessionMeasuredRow]
    ] = [:]
    private var measurementCacheLRU: [SessionMeasurementCacheKey] = []
    private var activeMeasurementCacheKey: SessionMeasurementCacheKey?
    private var layoutFingerprint = 0

    private var mountedHosts: [String: TranscriptRowHost] = [:]
    private var recycledHosts: [TranscriptRowHost] = []
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasuredHeights: [String: CGFloat] = [:]
    private var measurementCommitTask: Task<Void, Never>?

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
    private var scrollCommand = TranscriptScrollCommand()
    private var receivedSendAnimationToken: UInt64?
    private var pendingSendAnimationRequest: UserSendAnimationRequest?
    private var pendingSendAnimationRowKey: String?
    private var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    private var reduceMotion = false

    private var positionApplicationDepth = 0
    private var isApplyingPosition: Bool { positionApplicationDepth > 0 }
    private var lastDistanceFromBottom: CGFloat = 0
    private var lastBottomState: Bool?
    private var lastViewportSize: CGSize = .zero
    private var lastPrefetchOldestKey: String?
    private var isDetaching = false
    private var isRebuildingGeometry = false
    /// A status-bar tap scrolls without entering UIKit's ordinary dragging
    /// states. Track that native gesture as user movement so it exits follow
    /// mode and persists the position at the top.
    private var isExplicitUserScroll = false
    private var lastStableScrollState: SessionScrollState?

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        transcriptDocumentView.backgroundColor = .clear
        addSubview(transcriptDocumentView)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        measurementCommitTask?.cancel()
        disclosureAnchorReleaseTask?.cancel()
    }

    override func didMoveToWindow() {
        if window == nil, superview != nil {
            republishLastStableScrollState()
            isDetaching = true
        } else if window != nil {
            isDetaching = false
        }
        super.didMoveToWindow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isDetaching, !isRebuildingGeometry,
              bounds.width > 0, bounds.height > 0 else { return }

        let sizeChanged = abs(lastViewportSize.width - bounds.width) > 0.5
            || abs(lastViewportSize.height - bounds.height) > 0.5
        let widthChanged = abs(lastViewportSize.width - bounds.width) > 0.5
        lastViewportSize = bounds.size
        if widthChanged {
            _ = activateMeasurementCacheIfNeeded()
        }
        if sizeChanged {
            rebuildDocumentGeometry()
        } else {
            applyPendingInitialPositionIfPossible()
            updateMountedRows()
        }
        attachMountedHostingControllers()
        startPendingSendAnimationIfPossible()
    }

    func configure(
        rows newRows: [TranscriptVirtualRow],
        initialState: SessionScrollState?,
        followsLatest newFollowsLatest: Bool,
        hasOlderHistory newHasOlderHistory: Bool,
        layoutFingerprint newLayoutFingerprint: Int,
        scrollCommand newScrollCommand: TranscriptScrollCommand,
        sendAnimationRequest newSendAnimationRequest: UserSendAnimationRequest?,
        reduceMotion newReduceMotion: Bool,
        claimSendAnimation newClaimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void
    ) {
        rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        hasOlderHistory = newHasOlderHistory
        reduceMotion = newReduceMotion
        claimSendAnimation = newClaimSendAnimation

        if newSendAnimationRequest?.token != receivedSendAnimationToken {
            receivedSendAnimationToken = newSendAnimationRequest?.token
            pendingSendAnimationRequest = newSendAnimationRequest
            pendingSendAnimationRowKey = nil
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

        let geometryChanged = rows.count != newRows.count
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
            installExactSpacerMeasurements()
            refreshMountedRootViews()
            rebuildDocumentGeometry()
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        }

        if newScrollCommand != scrollCommand {
            scrollCommand = newScrollCommand
            lockedRestoreDistance = nil
            followsLatest = true
            scrollToBottom()
        }

        applyPendingInitialPositionIfPossible()
        startPendingSendAnimationIfPossible()
        checkForHistoryPrefetch()
        setNeedsLayout()
    }

    func prepareForDismantle() {
        republishLastStableScrollState()
        isDetaching = true
        for host in mountedHosts.values { host.detachHostingController() }
        for host in recycledHosts { host.detachHostingController() }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        isExplicitUserScroll = false
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        isExplicitUserScroll = true
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        isExplicitUserScroll = false
        emitViewportSnapshot()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance
        updateMountedRows()

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let isUserMovement = isTracking || isDragging || isDecelerating
            || isExplicitUserScroll
        if !isApplyingPosition, isUserMovement,
           distance > previousDistance + 0.5, followsLatest {
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

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { emitViewportSnapshot() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        emitViewportSnapshot()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        emitViewportSnapshot()
    }

    // MARK: Positioning

    private func rebuildDocumentGeometry(changedHeights: [String: CGFloat]? = nil) {
        guard !isRebuildingGeometry else { return }
        isRebuildingGeometry = true
        defer { isRebuildingGeometry = false }

        let previousLayout = virtualLayout
        let previousDistance = initialPositionApplied ? currentDistanceFromBottom() : nil
        let followsStreamingLatest = followsLatest && rows.contains { $0.id == .active }
        let visibleAnchorKey: String?
        if !followsStreamingLatest, let previousDistance, !previousLayout.isEmpty {
            let visibleRange = previousLayout.visibleRange(
                distanceFromBottom: previousDistance,
                viewportHeight: viewportHeight,
                overscanCount: 0
            )
            visibleAnchorKey = visibleRange.compactMap { index -> String? in
                guard previousLayout.keys.indices.contains(index) else { return nil }
                let key = previousLayout.keys[index]
                return measurements[key] == nil ? nil : key
            }.first ?? visibleRange.first.flatMap { index in
                previousLayout.keys.indices.contains(index)
                    ? previousLayout.keys[index]
                    : nil
            }
        } else {
            visibleAnchorKey = nil
        }
        let distanceToPreserve: CGFloat? = if let lockedRestoreDistance {
            lockedRestoreDistance
        } else if initialPositionApplied {
            followsStreamingLatest ? 0 : previousDistance
        } else {
            nil
        }

        var initialRestoreRange: Range<Int>?
        applyPositionTransaction {
            virtualLayout = incrementallyUpdatedLayout(changedHeights: changedHeights)
                ?? VirtualTranscriptLayout(
                    items: rows.map {
                        .init(key: $0.layoutKey, estimatedHeight: $0.estimatedHeight)
                    },
                    measuredHeights: measurements.heightsByKey,
                    spacing: Self.rowSpacing
                )
            initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
                virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
            }

            let documentHeight = max(1, Self.topPadding + virtualLayout.totalHeight)
            transcriptDocumentView.frame = CGRect(
                x: 0,
                y: 0,
                width: max(1, bounds.width),
                height: documentHeight
            )
            contentSize = transcriptDocumentView.bounds.size
            positionMountedRows()

            if !initialPositionApplied {
                applyPendingInitialPositionIfPossible()
            } else if let anchor = disclosureViewportAnchor {
                setViewportTop(anchor.viewportTop)
            } else if let distanceToPreserve {
                let anchoredDistance = visibleAnchorKey.flatMap { key in
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
            lastDistanceFromBottom = currentDistanceFromBottom()
        }
        updateMountedRows(rangeOverride: initialRestoreRange)
    }

    private func incrementallyUpdatedLayout(
        changedHeights: [String: CGFloat]?
    ) -> VirtualTranscriptLayout? {
        guard let changedHeights, !changedHeights.isEmpty,
              !virtualLayout.isEmpty,
              virtualLayout.keys.count == rows.count else { return nil }
        var layout = virtualLayout
        for (key, height) in changedHeights {
            guard let updated = layout.updatingHeight(forKey: key, to: height) else {
                return nil
            }
            layout = updated
        }
        return layout
    }

    private func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, viewportHeight > 0 else { return }
        let shouldPublishInitialPosition = lastStableScrollState == nil
            || (pendingInitialState?.isAtBottom == true && followsLatest)
        let restoredRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
            virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
        }
        updateMountedRows(rangeOverride: restoredRange)

        if let state = pendingInitialState, !state.isAtBottom {
            if state.distanceFromBottom > maximumOffsetY + 0.5, hasOlderHistory {
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
        if shouldPublishInitialPosition { emitViewportSnapshot() }
    }

    private var viewportHeight: CGFloat { max(0, bounds.height) }
    private var maximumOffsetY: CGFloat { max(0, contentSize.height - viewportHeight) }

    private func currentDistanceFromBottom() -> CGFloat {
        let boundedOffset = min(max(0, contentOffset.y), maximumOffsetY)
        return max(0, maximumOffsetY - boundedOffset)
    }

    private func setDistanceFromBottom(_ distance: CGFloat) {
        setViewportTop(maximumOffsetY - max(0, distance))
    }

    private func setViewportTop(_ requestedTop: CGFloat) {
        let top = min(max(0, requestedTop), maximumOffsetY)
        guard abs(contentOffset.y - top) > 0.25 else { return }
        applyPositionTransaction {
            setContentOffset(CGPoint(x: 0, y: top), animated: false)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
    }

    private func applyPositionTransaction(_ body: () -> Void) {
        positionApplicationDepth += 1
        defer { positionApplicationDepth -= 1 }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        UIView.performWithoutAnimation(body)
        CATransaction.commit()
    }

    private func scrollToBottom() {
        lockedRestoreDistance = nil
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
    }

    // MARK: Virtual rows and measurements

    private var effectiveRowWidth: CGFloat {
        let availableWidth = max(1, bounds.width - Self.horizontalPadding * 2)
        return min(Self.maxRowWidth, availableWidth)
    }

    @discardableResult
    private func activateMeasurementCacheIfNeeded() -> Bool {
        guard bounds.width > 0 else { return false }
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

        let provisionalMountedHeights = Dictionary(
            uniqueKeysWithValues: mountedHosts.keys.compactMap { mountedKey in
                measurements[mountedKey].map { (mountedKey, $0) }
            }
        )
        measurements.removeAll(keepingCapacity: true)
        let cached = measurementCaches[key] ?? [:]
        var valid: [String: SessionMeasuredRow] = [:]
        for row in rows {
            guard row.id.isCacheableSettledRow,
                  let measurement = cached[row.layoutKey],
                  measurement.revision == row.measurementRevision,
                  measurement.height > 0 else { continue }
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
           restore.measurementCacheKey == key {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey] else { continue }
                if row.id.isCacheableSettledRow {
                    guard restore.settledRowsByKey[rowKey]?.revision
                        == row.measurementRevision else { continue }
                }
                measurements.setProvisional(height, for: rowKey)
            }
        }
        return true
    }

    private func installExactSpacerMeasurements() {
        for row in rows {
            if case let .bottomSpacer(height) = row.content {
                measurements.setExact(height, for: row.layoutKey)
            }
        }
    }

    private func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow]
    ) {
        guard oldRows.contains(where: { $0.id == .active }),
              let activeHeight = measurements[TranscriptVirtualRow.ID.active.layoutKey],
              !newRows.contains(where: { $0.id == .active }) else { return }
        let oldKeys = Set(oldRows.map(\.layoutKey))
        let insertedSettledRows = newRows.filter {
            $0.id.isCacheableSettledRow && !oldKeys.contains($0.layoutKey)
        }
        guard insertedSettledRows.count == 1,
              let settledActive = insertedSettledRows.first,
              measurements[settledActive.layoutKey] == nil else { return }
        measurements.setProvisional(activeHeight, for: settledActive.layoutKey)
    }

    private func invalidateChangedMeasurements(
        previousRowsByKey: [String: TranscriptVirtualRow],
        newRows: [TranscriptVirtualRow]
    ) {
        for row in newRows {
            guard row.id.isCacheableSettledRow,
                  let previous = previousRowsByKey[row.layoutKey],
                  previous.measurementRevision != row.measurementRevision else { continue }
            let key = row.layoutKey
            measurements.markStale(key)
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

    private func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || viewportHeight > 0 else { return }
        let distance = currentDistanceFromBottom()
        let targetRange: Range<Int>
        if let rangeOverride {
            targetRange = rangeOverride
        } else {
            let visibleRange = virtualLayout.visibleRange(
                distanceFromBottom: distance,
                viewportHeight: viewportHeight,
                overscanCount: 0
            )
            let overscannedRange = virtualLayout.visibleRange(
                distanceFromBottom: distance,
                viewportHeight: viewportHeight,
                overscanCount: Self.overscanCount
            )
            let planIndices = overscannedRange.filter { index in
                guard virtualLayout.keys.indices.contains(index),
                      let row = rowByKey[virtualLayout.keys[index]] else { return false }
                return row.id.isPlanDocument
            }
            targetRange = VirtualTranscriptLayout.overscanRange(
                visibleRange: visibleRange,
                overscannedRange: overscannedRange,
                stoppingAt: planIndices
            )
        }

        let mountedIndices = mountedHosts.keys.compactMap { virtualLayout.indexByKey[$0] }
        let mountedRange: Range<Int>? = mountedIndices.min().flatMap { lower in
            mountedIndices.max().map { upper in lower..<(upper + 1) }
        }
        let range: Range<Int> = if rangeOverride == nil,
                                  let mountedRange,
                                  mountedRange.lowerBound <= targetRange.lowerBound,
                                  mountedRange.upperBound >= targetRange.upperBound {
            mountedRange
        } else {
            targetRange
        }
        let requiredKeys = Set(range.compactMap { index in
            virtualLayout.keys.indices.contains(index) ? virtualLayout.keys[index] : nil
        })

        for key in mountedHosts.keys.filter({ !requiredKeys.contains($0) }) {
            guard let host = mountedHosts.removeValue(forKey: key) else { continue }
            host.removeFromSuperview()
            if recycledHosts.count < 8 {
                recycledHosts.append(host)
            } else {
                host.detachHostingController()
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
                position(host: host, at: index)
                host.installHostingController(in: owningViewController)
                host.rootView = measuredRootView(for: row)
            }
        }
        attachMountedHostingControllers()
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
            guard let row = rowByKey[key],
                  previousRowsByKey[key]?.content != row.content else { continue }
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key)
        )
    }

    private func recordMeasuredHeight(_ rawHeight: CGFloat, for key: String) {
        let height = max(1, rawHeight.rounded(.up))
        guard rowByKey[key] != nil else { return }
        let needsCommit = pendingMeasuredHeights[key].map { abs($0 - height) > 0.5 }
            ?? measurements.needsCommit(height, for: key)
        guard needsCommit else { return }
        pendingMeasuredHeights[key] = height

        if key == TranscriptVirtualRow.ID.active.layoutKey {
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
                  measurements.needsCommit(height, for: key) else { continue }
            if storeMeasuredHeight(height, for: key) {
                committedHeights[key] = height
            }
        }
        if !committedHeights.isEmpty {
            rebuildDocumentGeometry(changedHeights: committedHeights)
        }
    }

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
        let availableWidth = max(1, bounds.width - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (bounds.width - rowWidth) / 2)
        let frame = CGRect(
            x: rowX,
            y: Self.topPadding + virtualLayout.topOffsets[index],
            width: rowWidth,
            height: virtualLayout.heights[index]
        )
        if host.frame != frame { host.frame = frame }
        host.setNeedsLayout()
    }

    // MARK: Stable state, prefetch, and animations

    private func checkForHistoryPrefetch(force: Bool = false) {
        guard !rows.isEmpty else { return }
        let distanceFromTop = min(max(0, contentOffset.y), maximumOffsetY)
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
        guard !isDetaching, initialPositionConfigured, viewportHeight > 0 else { return }
        let distance = currentDistanceFromBottom()
        publishBottomState(distance <= Self.atBottomThreshold)
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
                  virtualLayout.keys.indices.contains(first) else { return nil }
            return SessionRenderedTranscriptWindow(
                anchorKey: virtualLayout.keys[first],
                count: last - first + 1
            )
        }
        return SessionVirtualTranscriptRestoreState(
            measurementCacheKey: activeMeasurementCacheKey,
            rowHeightsByKey: measurements.heightsByKey,
            settledRowsByKey: settledRowHeightSnapshot,
            renderedWindow: renderedWindow
        )
    }

    private func publishBottomState(_ isAtBottom: Bool) {
        guard lastBottomState != isAtBottom else { return }
        lastBottomState = isAtBottom
        onBottomStateChange?(isAtBottom)
    }

    private func performAnchoredDisclosureChange(
        in rowKey: String,
        change: @escaping () -> Void
    ) {
        guard initialPositionApplied,
              virtualLayout.indexByKey[rowKey] != nil else {
            change()
            return
        }
        disclosureAnchorReleaseTask?.cancel()
        let anchor = DisclosureViewportAnchor(id: UUID(), viewportTop: contentOffset.y)
        disclosureViewportAnchor = anchor
        change()
        disclosureAnchorReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled,
                  self?.disclosureViewportAnchor?.id == anchor.id else { return }
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
              let rowKey = pendingSendAnimationRowKey,
              let claimSendAnimation else { return }

        func claimAndClear() -> Bool {
            let claimed = claimSendAnimation(request)
            pendingSendAnimationRequest = nil
            pendingSendAnimationRowKey = nil
            return claimed
        }

        guard !reduceMotion else {
            _ = claimAndClear()
            return
        }
        guard initialPositionApplied, bounds.width > 0, bounds.height > 0,
              let host = mountedHosts[rowKey] else { return }
        let bottomSpacerHeight = rows.last { $0.id == .bottomSpacer }.flatMap { row in
            if case let .bottomSpacer(height) = row.content { height } else { nil }
        } ?? 0
        let sourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
        let travel = sourceY - host.frame.minY
        guard travel > 1 else {
            _ = claimAndClear()
            return
        }
        guard claimAndClear() else { return }

        host.layer.removeAnimation(forKey: "codevisor.user-send")
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
        host.layer.add(group, forKey: "codevisor.user-send")
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    private func attachMountedHostingControllers() {
        guard let owningViewController else { return }
        for host in mountedHosts.values {
            host.installHostingController(in: owningViewController)
        }
    }
}
