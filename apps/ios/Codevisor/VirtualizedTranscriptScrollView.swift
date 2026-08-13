import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import UIKit

private struct TranscriptRowMeasurement {
    let key: String
    let revision: Int
    let rowWidthHalfPoints: Int
    let height: CGFloat
}

private enum TranscriptPixelGeometry {
    static func displayScale(for view: UIView) -> CGFloat {
        max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
    }

    static func ceil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded(.up) / scale
    }

    static func differs(_ lhs: CGFloat, _ rhs: CGFloat, scale: CGFloat) -> Bool {
        abs(lhs - rhs) * scale > 0.5
    }
}

/// Retained for the lifetime of the Core Animation group so first-send
/// promotion can wait for the visible row's actual presentation completion.
private final class TranscriptSendAnimationCompletion: NSObject, CAAnimationDelegate {
    private let completion: (Bool) -> Void

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func animationDidStop(_: CAAnimation, finished: Bool) {
        completion(finished)
    }
}

/// Measures one SwiftUI row at a fixed document width. The controller belongs
/// to `TranscriptViewController`, never to the surrounding navigation screen.
@MainActor
private final class TranscriptContentHostingController: UIHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?

    private var lastReportedHeight: CGFloat = 0
    private var measurementGeneration: UInt64 = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        // A transcript row lives in document coordinates. Its size must not
        // depend on whether it currently intersects screen chrome.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleMeasurement()
    }

    func installRootView(_ rootView: AnyView) {
        measurementGeneration &+= 1
        pendingMeasurementTask?.cancel()
        pendingMeasurementTask = nil
        lastReportedHeight = 0
        self.rootView = rootView
        invalidateContentSize()
    }

    func invalidateContentSize(forceReport: Bool = false) {
        if forceReport { lastReportedHeight = 0 }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.superview?.setNeedsLayout()
        scheduleMeasurement()
    }

    func resetReportedHeight() {
        lastReportedHeight = 0
    }

    private func scheduleMeasurement() {
        guard pendingMeasurementTask == nil else { return }
        let generation = measurementGeneration
        pendingMeasurementTask = Task { @MainActor [weak self] in
            // Root replacement and observed SwiftUI updates reconcile after
            // UIKit's current layout callback. Two yields keep an old root's
            // fitting size from becoming authoritative for the new revision.
            await Task.yield()
            await Task.yield()
            guard let self, !Task.isCancelled,
                  measurementGeneration == generation else { return }
            pendingMeasurementTask = nil
            view.layoutIfNeeded()
            measureAndReportHeight()
        }
    }

    private func measureAndReportHeight() {
        let width = view.bounds.width
        guard width > 1 else { return }
        let measured = sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude),
        ).height
        guard measured.isFinite, measured > 0 else { return }
        let scale = TranscriptPixelGeometry.displayScale(for: view)
        let height = max(1, TranscriptPixelGeometry.ceil(measured, scale: scale))
        guard TranscriptPixelGeometry.differs(lastReportedHeight, height, scale: scale) else {
            return
        }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }
}

/// A stable, identity-bound row host. Its SwiftUI content owns natural height;
/// the virtualizer supplies only document position and width.
@MainActor
private final class TranscriptRowHost: UIView {
    private let contentController = TranscriptContentHostingController(
        rootView: AnyView(EmptyView()),
    )
    private var contentHost: UIView {
        contentController.view
    }

    private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(
        equalToConstant: 1,
    )

    private(set) var representedRow: TranscriptVirtualRow?
    private(set) var isPresentationReady = false
    var onMeasuredHeight: ((TranscriptRowMeasurement) -> Void)?

    init(parent: UIViewController) {
        super.init(frame: .zero)
        backgroundColor = .clear
        // The virtualizer is the only owner of row geometry. Until a natural
        // height has been committed, keep the hosted content inside the
        // current ledger frame so an estimate can never paint over its
        // neighbor.
        clipsToBounds = true

        parent.addChild(contentController)
        let hostedView = contentController.view!
        hostedView.backgroundColor = .clear
        hostedView.clipsToBounds = false
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.setContentHuggingPriority(.required, for: .vertical)
        hostedView.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentWidthConstraint,
        ])
        contentController.didMove(toParent: parent)
        contentController.onLaidOutHeightChange = { [weak self] height in
            self?.contentHeightDidChange(height)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        if syncContentWidth() {
            contentController.invalidateContentSize(forceReport: true)
        }
        super.layoutSubviews()
    }

    @discardableResult
    func syncContentWidth() -> Bool {
        let width = max(1, bounds.width)
        guard abs(contentWidthConstraint.constant - width) > 0.5 else { return false }
        contentWidthConstraint.constant = width
        return true
    }

    func install(row: TranscriptVirtualRow, rootView: AnyView, force: Bool = false) {
        let representsDifferentRow = representedRow?.layoutKey != row.layoutKey
        let needsRoot = force
            || representedRow?.content != row.content
            || representedRow?.measurementRevision != row.measurementRevision
        representedRow = row
        guard needsRoot else { return }
        isPresentationReady = false
        // An optimistic message can become settled while its lift is still in
        // flight. Preserve the wrapper animation when the stable row identity
        // is unchanged; only reused hosts may discard another row's animation.
        if representsDifferentRow {
            layer.removeAnimation(forKey: "codevisor.user-send")
        }
        contentController.installRootView(rootView)
    }

    func requestContentMeasurement(forceReport: Bool = true) {
        contentController.invalidateContentSize(forceReport: forceReport)
    }

    func resetReportedContentHeight() {
        isPresentationReady = false
        contentController.resetReportedHeight()
    }

    func detachFromParent() {
        contentController.onLaidOutHeightChange = nil
        guard contentController.parent != nil else { return }
        contentController.willMove(toParent: nil)
        contentController.view.removeFromSuperview()
        contentController.removeFromParent()
    }

    private func contentHeightDidChange(_ rawHeight: CGFloat) {
        guard let row = representedRow else { return }
        let scale = TranscriptPixelGeometry.displayScale(for: contentHost)
        let height = max(1, TranscriptPixelGeometry.ceil(rawHeight, scale: scale))

        // Do not resize this wrapper independently. The callback commits the
        // height, following offsets, document size, and every mounted frame in
        // one non-animated virtual-layout transaction before UIKit paints.
        isPresentationReady = true
        onMeasuredHeight?(.init(
            key: row.layoutKey,
            revision: row.measurementRevision,
            rowWidthHalfPoints: Int((contentWidthConstraint.constant * 2).rounded()),
            height: height,
        ))
    }
}

/// The only controller SwiftUI installs for a transcript. It is a real UIKit
/// containment boundary: row hosting controllers are descendants of this
/// controller, not siblings injected into the navigation destination.
@MainActor
final class TranscriptViewController: UIViewController {
    private let transcriptScrollView = VirtualizedTranscriptScrollView()

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .clear
        view = root

        transcriptScrollView.hostingParent = self
        transcriptScrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(transcriptScrollView)
        NSLayoutConstraint.activate([
            transcriptScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            transcriptScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcriptScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcriptScrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    func configure(
        rows: [TranscriptVirtualRow],
        initialState: SessionScrollState?,
        followsLatest: Bool,
        hasOlderHistory: Bool,
        isLoadingInitialHistory: Bool,
        layoutFingerprint: Int,
        scrollCommand: TranscriptScrollCommand,
        sendAnimationRequest: UserSendAnimationRequest?,
        sendAnimationSourceFrame: CGRect?,
        presentationRole: TranscriptPresentationRole,
        reduceMotion: Bool,
        claimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        onSendAnimationStarted: ((
            UserSendAnimationRequest,
            TranscriptSendAnimationTarget
        ) -> Bool)?,
        onSendAnimationCompleted: @escaping (UserSendAnimationRequest) -> Void,
        rowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void,
    ) {
        loadViewIfNeeded()
        transcriptScrollView.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            isLoadingInitialHistory: isLoadingInitialHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            sendAnimationRequest: sendAnimationRequest,
            sendAnimationSourceFrame: sendAnimationSourceFrame,
            presentationRole: presentationRole,
            reduceMotion: reduceMotion,
            claimSendAnimation: claimSendAnimation,
            onSendAnimationStarted: onSendAnimationStarted,
            onSendAnimationCompleted: onSendAnimationCompleted,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop,
        )
    }

    func prepareForDismantle() {
        transcriptScrollView.prepareForDismantle()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        transcriptScrollView.discardParkedHosts()
    }
}

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
    weak var hostingParent: UIViewController?

    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var virtualLayout = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: rowSpacing,
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
    private var parkedHosts: [String: TranscriptRowHost] = [:]
    private var parkedHostLRU: [String] = []
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasurements: [String: TranscriptRowMeasurement] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    private var measurementCommitGate = TranscriptMeasurementCommitGate()
    private var initialPresentationGate = TranscriptInitialPresentationGate()
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
    private var isLoadingInitialHistory = false
    private var scrollCommand = TranscriptScrollCommand()
    private var receivedSendAnimationToken: UInt64?
    private var pendingSendAnimationRequest: UserSendAnimationRequest?
    private var pendingSendAnimationRowKey: String?
    private var sendAnimationSourceFrame: CGRect?
    private var claimSendAnimation: ((UserSendAnimationRequest) -> Bool)?
    private var onSendAnimationStarted: ((
        UserSendAnimationRequest,
        TranscriptSendAnimationTarget
    ) -> Bool)?
    private var onSendAnimationCompleted: ((UserSendAnimationRequest) -> Void)?
    private var activeSendAnimationRequest: UserSendAnimationRequest?
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

    private var isNativeScrollInteractionActive: Bool {
        isTracking || isDragging || isDecelerating || isExplicitUserScroll
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        canvasView.backgroundColor = .clear
        addSubview(canvasView)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isDetaching else { return }
        updateTopContentInsetIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else { return }

        let widthChanged = abs(lastViewportSize.width - bounds.width) > 0.5
        lastViewportSize = bounds.size
        if widthChanged {
            discardParkedHosts()
            _ = activateMeasurementCacheIfNeeded()
            rebuildDocumentGeometry()
        } else {
            applyPendingInitialPositionIfPossible()
            updateMountedRows()
        }
        startPendingSendAnimationIfPossible()
        updateInitialPresentationReadiness()
    }

    func configure(
        rows newRows: [TranscriptVirtualRow],
        initialState: SessionScrollState?,
        followsLatest newFollowsLatest: Bool,
        hasOlderHistory newHasOlderHistory: Bool,
        isLoadingInitialHistory newIsLoadingInitialHistory: Bool,
        layoutFingerprint newLayoutFingerprint: Int,
        scrollCommand newScrollCommand: TranscriptScrollCommand,
        sendAnimationRequest newSendAnimationRequest: UserSendAnimationRequest?,
        sendAnimationSourceFrame newSendAnimationSourceFrame: CGRect?,
        presentationRole newPresentationRole: TranscriptPresentationRole,
        reduceMotion newReduceMotion: Bool,
        claimSendAnimation newClaimSendAnimation: @escaping (UserSendAnimationRequest) -> Bool,
        onSendAnimationStarted newOnSendAnimationStarted: ((
            UserSendAnimationRequest,
            TranscriptSendAnimationTarget
        ) -> Bool)?,
        onSendAnimationCompleted newOnSendAnimationCompleted: @escaping (
            UserSendAnimationRequest
        ) -> Void,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void,
    ) {
        rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        hasOlderHistory = newHasOlderHistory
        isLoadingInitialHistory = newIsLoadingInitialHistory
        reduceMotion = newReduceMotion
        sendAnimationSourceFrame = newSendAnimationSourceFrame
        claimSendAnimation = newClaimSendAnimation
        onSendAnimationStarted = newOnSendAnimationStarted
        onSendAnimationCompleted = newOnSendAnimationCompleted
        let becameForeground = presentationRole != .foreground
            && newPresentationRole == .foreground
        presentationRole = newPresentationRole

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

        let prependedItemCount = reversePrependCount(from: rows, to: newRows)
        if prependedItemCount != nil, isNativeScrollInteractionActive,
           !layoutFingerprintChanged
        {
            deferredRowsDuringScroll = newRows
        } else {
            deferredRowsDuringScroll = nil
            applyRows(newRows, layoutFingerprintChanged: layoutFingerprintChanged)
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
        setNeedsLayout()
    }

    func prepareForDismantle() {
        republishLastStableScrollState()
        isDetaching = true
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        pendingMeasurements.removeAll(keepingCapacity: false)
        deferredRowsDuringScroll = nil
        disclosureAnchorReleaseTask?.cancel()
        sendAnimationCompletion = nil
        activeSendAnimationRequest = nil
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

    private func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool,
    ) {
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
            refreshMountedRootViews()
            rebuildDocumentGeometry()
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            evictChangedParkedHosts(previousRowsByKey: previousRowsByKey)
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        }
    }

    private func reversePrependCount(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
    ) -> Int? {
        guard !oldRows.isEmpty, newRows.count > oldRows.count else { return nil }
        let insertedCount = newRows.count - oldRows.count
        guard zip(oldRows, newRows.dropFirst(insertedCount)).allSatisfy({ old, new in
            old.id == new.id
        }) else { return nil }
        return insertedCount
    }

    private func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow],
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
        newRows: [TranscriptVirtualRow],
    ) {
        for row in newRows {
            guard row.id.isCacheableSettledRow,
                  let previous = previousRowsByKey[row.layoutKey],
                  previous.measurementRevision != row.measurementRevision else { continue }
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
                  measurement.height > 0 else { continue }
            valid[row.layoutKey] = measurement
            measurements.setExact(measurement.height, for: row.layoutKey)
        }
        settledRowHeightSnapshot = valid
        measurementCaches[key] = valid
        installExactSpacerMeasurements()
        for (mountedKey, height) in provisionalMountedHeights
            where measurements[mountedKey] == nil
        {
            measurements.setProvisional(height, for: mountedKey)
        }

        if let restore = pendingInitialState?.virtualTranscript,
           restore.measurementCacheKey == key
        {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey], measurements[rowKey] == nil else { continue }
                if row.id.isCacheableSettledRow {
                    guard let settled = restore.settledRowsByKey[rowKey],
                          settled.revision == row.measurementRevision else { continue }
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
        let followsStreamingLatest = followsLatest && rows.contains { $0.id == .active }
        let visibleAnchorKey: String?
        if !followsStreamingLatest, let previousDistance, !previousLayout.isEmpty {
            let visibleRange = previousLayout.visibleRange(
                distanceFromBottom: previousDistance,
                viewportHeight: viewportHeight,
                overscanCount: 0,
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
            followsStreamingLatest ? 0 : currentDistanceFromBottom()
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
                    spacing: Self.rowSpacing,
                )
            initialRestoreRange = pendingInitialState?.virtualTranscript?.renderedWindow.flatMap {
                virtualLayout.renderedRange(anchorKey: $0.anchorKey, count: $0.count)
            }

            let documentSize = CGSize(
                width: max(1, bounds.width),
                height: max(1, Self.topPadding + virtualLayout.totalHeight),
            )
            contentSize = documentSize
            canvasView.frame = CGRect(origin: .zero, size: documentSize)
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

    // MARK: - Viewport

    private var viewportHeight: CGFloat {
        max(0, bounds.height)
    }

    private var viewportGeometry: VirtualTranscriptViewport {
        VirtualTranscriptViewport(
            contentHeight: max(1, Self.topPadding + virtualLayout.totalHeight),
            viewportHeight: viewportHeight,
            topInset: appliedTopContentInset,
        )
    }

    private func currentDistanceFromBottom() -> CGFloat {
        viewportGeometry.distanceFromBottom(offsetY: contentOffset.y)
    }

    private func setDistanceFromBottom(_ distance: CGFloat) {
        setViewportTop(viewportGeometry.offsetY(distanceFromBottom: distance))
    }

    private func setViewportTop(_ requestedTop: CGFloat) {
        let top = viewportGeometry.boundedOffsetY(requestedTop)
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

    private func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, viewportHeight > 0 else { return }
        let shouldPublishInitialPosition = lastStableScrollState == nil
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

    private func scrollToBottom() {
        lockedRestoreDistance = nil
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
    }

    // MARK: - Native scrolling

    func scrollViewWillBeginDragging(_: UIScrollView) {
        measurementCommitGate.draggingDidBegin()
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        isExplicitUserScroll = false
        // Touching down interrupts UIKit's deceleration. Flush measurements
        // retained from that momentum phase before the new drag advances.
        commitPendingMeasurements()
    }

    func scrollViewShouldScrollToTop(_: UIScrollView) -> Bool {
        cancelDisclosureViewportAnchor()
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

        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let isUserMovement = isTracking || isDragging || isDecelerating
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
              let hostingParent else { return }
        let targetRange: Range<Int>
        if let rangeOverride {
            targetRange = rangeOverride
        } else {
            targetRange = plannedMountedRange()
        }

        let mountedIndices = mountedHosts.keys.compactMap { virtualLayout.indexByKey[$0] }
        let mountedRange: Range<Int>? = mountedIndices.min().flatMap { lower in
            mountedIndices.max().map { upper in lower ..< (upper + 1) }
        }
        let range: Range<Int> = if rangeOverride == nil,
                                   let mountedRange,
                                   mountedRange.lowerBound <= targetRange.lowerBound,
                                   mountedRange.upperBound >= targetRange.upperBound
        {
            mountedRange
        } else {
            targetRange
        }
        let requiredKeys = Set(range.compactMap { index in
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
            guard let row = rowByKey[key],
                  previousRowsByKey[key]?.content != row.content else { continue }
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
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key),
        )
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
            y: Self.topPadding + virtualLayout.topOffsets[index],
            width: rowWidth,
            height: virtualLayout.heights[index],
        )
        if host.frame != nextFrame {
            host.frame = nextFrame
        }
        host.syncContentWidth()
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
        let needsCommit = pendingMeasurements[measurement.key].map {
            $0.revision != measurement.revision
                || $0.rowWidthHalfPoints != measurement.rowWidthHalfPoints
                || TranscriptPixelGeometry.differs(
                    $0.height,
                    measurement.height,
                    scale: scale,
                )
        } ?? measurements.needsCommit(measurement.height, for: measurement.key)
        guard needsCommit else {
            startPendingSendAnimationIfPossible()
            return
        }
        pendingMeasurements[measurement.key] = measurement
        // Active output needs its latest geometry without an extra frame.
        // Ordinary mounted rows batch into one document snapshot, matching
        // the macOS virtualizer and avoiding redundant anchor corrections.
        guard measurementCommitGate.allowsGeometryCommit else { return }
        if measurement.key == TranscriptVirtualRow.ID.active.layoutKey {
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
                  measurements.needsCommit(measurement.height, for: key) else { continue }
            if storeMeasuredHeight(measurement.height, for: key) {
                committedHeights[key] = measurement.height
            }
        }
        if !committedHeights.isEmpty {
            rebuildDocumentGeometry(changedHeights: committedHeights)
        }
        updateInitialPresentationReadiness()
        startPendingSendAnimationIfPossible()
    }

    private func updateInitialPresentationReadiness() {
        guard !initialPresentationGate.isReady,
              !isDetaching,
              initialPositionApplied,
              viewportHeight > 0 else { return }

        let requiredKeys = Set(plannedMountedRange().compactMap { index in
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
        let resolvedKeys = Set(requiredKeys.filter { key in
            measurements[key] != nil && !measurements.isStale(key)
        })
        guard initialPresentationGate.resolve(
            isHydrating: isLoadingInitialHistory,
            requiredKeys: requiredKeys,
            resolvedKeys: resolvedKeys,
        ) else { return }

        applyPositionTransaction {
            canvasView.alpha = 1
            canvasView.accessibilityElementsHidden = false
        }
        isScrollEnabled = true
    }

    private func accepts(_ measurement: TranscriptRowMeasurement) -> Bool {
        guard let row = rowByKey[measurement.key],
              row.measurementRevision == measurement.revision,
              measurement.rowWidthHalfPoints
              == Int((effectiveRowWidth * 2).rounded()) else { return false }
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
              let rowKey = pendingSendAnimationRowKey else { return }
        guard initialPositionApplied, bounds.width > 0, bounds.height > 0,
              let host = mountedHosts[rowKey], host.isPresentationReady else { return }

        // Prewarmed destinations do not own animation consumption, but their
        // full-screen layout is the authoritative endpoint for New Chat's
        // flight layer. Report it before the foreground-only claim gate.
        let usesExternalFlight: Bool
        if let onSendAnimationStarted,
           let target = sendAnimationTarget(in: host, rowKey: rowKey) {
            usesExternalFlight = onSendAnimationStarted(request, target)
        } else {
            usesExternalFlight = false
        }
        guard presentationRole == .foreground,
              let claimSendAnimation else { return }

        func claimAndClear() -> Bool {
            let claimed = claimSendAnimation(request)
            pendingSendAnimationRequest = nil
            pendingSendAnimationRowKey = nil
            return claimed
        }

        func claimAndCompleteWithoutAnimation() {
            guard claimAndClear() else { return }
            onSendAnimationCompleted?(request)
        }

        guard !reduceMotion else {
            claimAndCompleteWithoutAnimation()
            return
        }
        let bottomSpacerHeight = rows.last { $0.id == .bottomSpacer }.flatMap { row in
            if case let .bottomSpacer(height) = row.content { height } else { nil }
        } ?? 0
        let fallbackSourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
        // Composer reports its editor frame in the global SwiftUI coordinate
        // space, which maps to window coordinates on iOS. Converting through
        // the canvas gives the row animation the real launch position rather
        // than an estimated offset above the bottom spacer.
        let sourceY = sendAnimationSourceFrame.map { sourceFrame in
            canvasView.convert(
                CGPoint(x: sourceFrame.midX, y: sourceFrame.midY),
                from: nil
            ).y
        } ?? fallbackSourceY
        guard let plan = TranscriptSendAnimationMetrics.plan(
            sourceY: sourceY,
            targetY: host.frame.minY
        ) else {
            claimAndCompleteWithoutAnimation()
            return
        }
        guard claimAndClear() else { return }

        host.layer.removeAnimation(forKey: "codevisor.user-send")
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
                  self.activeSendAnimationRequest?.token == request.token else { return }
            host.layer.opacity = 1
            self.activeSendAnimationRequest = nil
            self.sendAnimationCompletion = nil
            self.onSendAnimationCompleted?(request)
        }
        sendAnimationCompletion = completion
        group.delegate = completion
        host.layer.add(group, forKey: "codevisor.user-send")
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
              !isDetaching, initialPositionConfigured, viewportHeight > 0 else { return }
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
                  virtualLayout.keys.indices.contains(first) else { return nil }
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
