import CodevisorCore
import CodevisorUI
import QuartzCore
import SwiftUI
import UIKit

@MainActor
private final class TranscriptContentHostingController: UIHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        // Transcript rows live in document coordinates, not screen-safe-area
        // coordinates. If a child host observes the parent's container safe
        // area, its SwiftUI root is inset as the cell crosses the top chrome.
        // That both moves pixels inside a stationary virtual row and makes
        // sizeThatFits include location-dependent blank space.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureAndReportHeight()
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    func invalidateContentSize(forceReport: Bool = false) {
        if forceReport { lastReportedHeight = 0 }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.superview?.setNeedsLayout()
        guard pendingMeasurementTask == nil else { return }
        pendingMeasurementTask = Task { @MainActor [weak self] in
            // UIHostingController.rootView is reconciled asynchronously. A
            // fresh controller makes stale reuse impossible; yielding here
            // lets that new root establish its intrinsic size before it is
            // allowed to affect collection geometry.
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingMeasurementTask = nil
            self.view.superview?.layoutIfNeeded()
            self.view.layoutIfNeeded()
            self.measureAndReportHeight()
        }
    }

    private func measureAndReportHeight() {
        let width = view.bounds.width
        guard width > 1 else { return }
        let height = max(
            1,
            sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height.rounded(.up)
        )
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }
}

/// A measurement is valid only for the exact rendered row generation and
/// width that produced it. This prevents a delayed UIKit/SwiftUI layout pass
/// from writing an old root's height into a reused cell or a newer revision.
private struct TranscriptCellMeasurement: Equatable {
    let key: String
    let revision: Int
    let rowWidthHalfPoints: Int
    let height: CGFloat
}

private struct TranscriptMeasurementSignature: Hashable {
    let key: String
    let revision: Int
    let rowWidthHalfPoints: Int
    let contentGeneration: UInt64
}

private struct TranscriptSettledMeasurementRequest {
    let signature: TranscriptMeasurementSignature
    let rootView: AnyView
}

/// UICollectionView owns touch tracking, momentum, reuse, and layout-update
/// transactions on iOS. The shared virtual layout remains the source of truth
/// for estimated/exact row geometry; this adapter only translates that
/// geometry into native collection-view attributes.
@MainActor
private final class TranscriptCollectionLayout: UICollectionViewLayout {
    static let rowSpacing: CGFloat = 20
    static let topPadding: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let maxRowWidth: CGFloat = 832
    static let overscanCount = 2

    private(set) var transcriptGeometry = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: rowSpacing
    )
    private var overscanBarriers: [Int] = []

    func setGeometry(
        _ geometry: VirtualTranscriptLayout,
        overscanBarriers: [Int],
        contentOffsetAdjustment: CGFloat
    ) {
        transcriptGeometry = geometry
        self.overscanBarriers = overscanBarriers
        let context = UICollectionViewLayoutInvalidationContext()
        context.contentOffsetAdjustment = CGPoint(x: 0, y: contentOffsetAdjustment)
        invalidateLayout(with: context)
    }

    override var collectionViewContentSize: CGSize {
        CGSize(
            width: max(1, collectionView?.bounds.width ?? 1),
            height: max(1, Self.topPadding + transcriptGeometry.totalHeight)
        )
    }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        guard !transcriptGeometry.isEmpty else { return [] }
        let documentTop = max(0, rect.minY - Self.topPadding)
        let documentHeight = max(1, rect.height)
        let distanceFromBottom = transcriptGeometry.distanceFromBottom(
            viewportTop: documentTop,
            viewportHeight: documentHeight
        )
        let visibleRange = transcriptGeometry.visibleRange(
            distanceFromBottom: distanceFromBottom,
            viewportHeight: documentHeight,
            overscanCount: 0
        )
        let overscannedRange = transcriptGeometry.visibleRange(
            distanceFromBottom: distanceFromBottom,
            viewportHeight: documentHeight,
            overscanCount: Self.overscanCount
        )
        let range = VirtualTranscriptLayout.overscanRange(
            visibleRange: visibleRange,
            overscannedRange: overscannedRange,
            stoppingAt: overscanBarriers
        )
        return range.compactMap { layoutAttributesForItem(at: IndexPath(item: $0, section: 0)) }
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0,
              transcriptGeometry.heights.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame(at: indexPath.item)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return abs(collectionView.bounds.width - newBounds.width) > 0.5
    }

    func frame(at index: Int) -> CGRect {
        guard transcriptGeometry.heights.indices.contains(index) else { return .zero }
        let collectionWidth = max(1, collectionView?.bounds.width ?? 1)
        let availableWidth = max(1, collectionWidth - Self.horizontalPadding * 2)
        let rowWidth = min(Self.maxRowWidth, availableWidth)
        let rowX = max(Self.horizontalPadding, (collectionWidth - rowWidth) / 2)
        return CGRect(
            x: rowX,
            y: Self.topPadding + transcriptGeometry.topOffsets[index],
            width: rowWidth,
            height: transcriptGeometry.heights[index]
        )
    }
}

/// A reusable SwiftUI-backed collection cell. It measures the root at its
/// natural width and reports that value to the shared measurement ledger.
/// Reused pixels stay hidden until the cell's native layout slot agrees with
/// the newly rendered root, preventing stale or compressed content flashes.
@MainActor
private final class TranscriptCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "TranscriptCollectionCell"

    private var contentController: TranscriptContentHostingController?
    private var contentHost: UIView? { contentController?.view }
    private var contentHostConstraints: [NSLayoutConstraint] = []
    private var authoritativeContentHeightConstraint: NSLayoutConstraint?
    private weak var installedParent: UIViewController?
    private var lastContentWidth: CGFloat = 0
    private var measuredContentHeight: CGFloat?
    private var expectedHeight: CGFloat = 1
    private var hasAuthoritativeExpectedHeight = false
    private var configurationGeneration: UInt64 = 0

    private(set) var representedKey: String?
    private(set) var representedRevision: Int?
    var onMeasuredHeight: ((TranscriptCellMeasurement) -> Void)?
    var onPresentationReady: ((String) -> Void)?
    var isPresentationReady: Bool { contentHost?.isHidden == false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        clipsToBounds = false
        contentView.clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configurationGeneration &+= 1
        representedKey = nil
        representedRevision = nil
        measuredContentHeight = nil
        hasAuthoritativeExpectedHeight = false
        layer.removeAnimation(forKey: "codevisor.user-send")
        removeContentController()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The host is pinned to contentView's edges, so its width is knowable
        // without forcing a synchronous Auto Layout + SwiftUI solve here.
        // Forcing one ran the full solve inside the scroll gesture's frame
        // budget for every cell entering the viewport.
        let width = max(1, contentView.bounds.width)
        if abs(lastContentWidth - width) > 0.5 {
            lastContentWidth = width
            contentController?.invalidateContentSize(forceReport: true)
        }
        revealContentIfGeometryIsValid()
    }

    func configure(
        key: String,
        revision: Int,
        rootView: AnyView,
        adoptedController: TranscriptContentHostingController?,
        expectedHeight: CGFloat,
        hasAuthoritativeExpectedHeight: Bool,
        parent: UIViewController?
    ) {
        configurationGeneration &+= 1
        let generation = configurationGeneration
        representedKey = key
        representedRevision = revision
        self.expectedHeight = expectedHeight
        self.hasAuthoritativeExpectedHeight = hasAuthoritativeExpectedHeight
        measuredContentHeight = nil
        layer.removeAnimation(forKey: "codevisor.user-send")

        // UIHostingController can briefly return the previous root's fitting
        // size after rootView replacement. Reusing that controller is enough
        // to poison a different virtual row with a perfectly plausible but
        // wrong height. Recreate only the small visible/overscan host subtree;
        // UICollectionView still owns and reuses the outer cells.
        //
        // Measure-once, display-the-same-host: when the settled measurer has
        // already built this exact (key, revision, width, generation) tree
        // off-screen, adopt it instead of rebuilding the SwiftUI subtree —
        // the dominant first-scroll cost. Adoption is immune to the stale-size
        // reuse bug above because an adopted controller's rootView is never
        // replaced.
        removeContentController()
        let controller = adoptedController
            ?? TranscriptContentHostingController(rootView: rootView)
        contentController = controller
        controller.sizingOptions = [.intrinsicContentSize]
        let host = controller.view!
        host.backgroundColor = .clear
        host.clipsToBounds = false
        host.isHidden = true
        // Reset the off-screen measurement presentation on adopted hosts.
        host.alpha = 1
        host.isUserInteractionEnabled = true
        host.accessibilityElementsHidden = false
        host.translatesAutoresizingMaskIntoConstraints = false
        host.setContentHuggingPriority(.required, for: .vertical)
        host.setContentCompressionResistancePriority(.required, for: .vertical)
        contentView.addSubview(host)
        contentHostConstraints = [
            host.topAnchor.constraint(equalTo: contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(contentHostConstraints)
        updateAuthoritativeContentHeightConstraint()
        installHostingController(in: parent)
        controller.onLaidOutHeightChange = { [weak self, weak controller] height in
            guard let self, let controller,
                  self.contentController === controller,
                  self.configurationGeneration == generation else { return }
            self.contentHeightDidChange(height)
        }
        // A provisional virtual slot owns only position and width. Its estimate
        // must never constrain the hosted SwiftUI subtree, otherwise a 320pt
        // estimate can report itself back as an exact 320pt measurement. Once
        // off-cell measurement establishes authority, the exact height
        // constraint is installed by updateAuthoritativeContentHeightConstraint.
        //
        // Layout is deliberately not forced here: a synchronous layoutIfNeeded
        // ran a full Auto Layout + SwiftUI solve during cellForItemAt — inside
        // the scroll gesture's frame budget — at a width the incoming cell
        // frame then invalidated anyway. layoutSubviews records the real width
        // and re-invalidates once the native layout slot has been applied.
        lastContentWidth = 0
        controller.invalidateContentSize(forceReport: true)
        setNeedsLayout()
    }

    func updateExpectedHeight(_ height: CGFloat, isAuthoritative: Bool) {
        expectedHeight = height
        hasAuthoritativeExpectedHeight = isAuthoritative
        updateAuthoritativeContentHeightConstraint()
        revealContentIfGeometryIsValid()
    }

    func requestContentMeasurement() {
        contentController?.invalidateContentSize(forceReport: true)
    }

    func installHostingController(in parent: UIViewController?) {
        guard let controller = contentController,
              let parent,
              installedParent !== parent else { return }
        detachHostingController()
        parent.addChild(controller)
        controller.didMove(toParent: parent)
        installedParent = parent
    }

    func detachHostingController() {
        guard let controller = contentController,
              controller.parent != nil else {
            installedParent = nil
            return
        }
        controller.willMove(toParent: nil)
        controller.removeFromParent()
        installedParent = nil
    }

    private func removeContentController() {
        guard let controller = contentController else { return }
        controller.onLaidOutHeightChange = nil
        detachHostingController()
        NSLayoutConstraint.deactivate(contentHostConstraints)
        contentHostConstraints.removeAll(keepingCapacity: true)
        authoritativeContentHeightConstraint?.isActive = false
        authoritativeContentHeightConstraint = nil
        controller.view.removeFromSuperview()
        contentController = nil
        lastContentWidth = 0
    }

    private func contentHeightDidChange(_ rawHeight: CGFloat) {
        guard let representedKey, let representedRevision,
              let contentHost else { return }
        let height = max(1, rawHeight.rounded(.up))
        measuredContentHeight = height
        onMeasuredHeight?(.init(
            key: representedKey,
            revision: representedRevision,
            rowWidthHalfPoints: Int((contentHost.bounds.width * 2).rounded()),
            height: height
        ))
        revealContentIfGeometryIsValid()
    }

    private func updateAuthoritativeContentHeightConstraint() {
        guard let contentHost else { return }
        guard hasAuthoritativeExpectedHeight else {
            authoritativeContentHeightConstraint?.isActive = false
            authoritativeContentHeightConstraint = nil
            return
        }
        if let authoritativeContentHeightConstraint {
            authoritativeContentHeightConstraint.constant = expectedHeight
        } else {
            let constraint = contentHost.heightAnchor.constraint(equalToConstant: expectedHeight)
            constraint.priority = .required
            constraint.isActive = true
            authoritativeContentHeightConstraint = constraint
        }
    }

    private func revealContentIfGeometryIsValid() {
        guard let representedKey, let contentHost,
              abs(bounds.height - expectedHeight) <= 0.5 else { return }
        if !hasAuthoritativeExpectedHeight {
            guard let measuredContentHeight,
                  abs(expectedHeight - measuredContentHeight) <= 0.5 else { return }
        }
        let becameReady = contentHost.isHidden
        contentHost.isHidden = false
        if becameReady { onPresentationReady?(representedKey) }
    }
}

/// The iOS transcript adapter. UICollectionView remains the sole owner of
/// native scroll physics; all geometry changes flow through its invalidation
/// transaction so an active pan never has its translation or velocity reset.
@MainActor
final class CollectionTranscriptView: UICollectionView,
    UICollectionViewDataSource,
    UICollectionViewDelegate
{
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3
    private static let sendAnimationDuration: CFTimeInterval = 0.46
    /// Main-thread time one pipeline turn may spend measuring rows before it
    /// sleeps for a frame to let touch delivery and rendering run.
    private static let settledMeasurementTurnBudget: CFAbsoluteTime = 0.004

    private let transcriptLayout: TranscriptCollectionLayout
    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var virtualLayout = VirtualTranscriptLayout(
        items: [],
        measuredHeights: [:],
        spacing: TranscriptCollectionLayout.rowSpacing
    )
    private var measurements = TranscriptMeasurementLedger()
    private var settledRowHeightSnapshot: [String: SessionMeasuredRow] = [:]
    private var measurementCaches: [
        SessionMeasurementCacheKey: [String: SessionMeasuredRow]
    ] = [:]
    private var measurementCacheLRU: [SessionMeasurementCacheKey] = []
    private var activeMeasurementCacheKey: SessionMeasurementCacheKey?
    private var layoutFingerprint = 0
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasurements: [String: TranscriptCellMeasurement] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    private var settledMeasurementQueue: [TranscriptSettledMeasurementRequest] = []
    private var queuedSettledMeasurementSignatures: Set<TranscriptMeasurementSignature> = []
    private var settledMeasurementTask: Task<Void, Never>?
    private var deferredRowsDuringScroll: [TranscriptVirtualRow]?
    private var settledMeasurementGenerations: [String: UInt64] = [:]
    private var measurementCommitGate = TranscriptMeasurementCommitGate()

    /// Fully-built hosts parked by the settled measurer, keyed by the same
    /// signature that validates their measurements. Display cells adopt these
    /// so each row's SwiftUI tree is built exactly once.
    private var pooledMeasuredHosts:
        [TranscriptMeasurementSignature: TranscriptContentHostingController] = [:]
    private var pooledMeasuredHostLRU: [TranscriptMeasurementSignature] = []
    private static let maxPooledMeasuredHosts = 24

    private struct DisclosureViewportAnchor {
        let id: UUID
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
    private var isExplicitUserScroll = false
    private var lastStableScrollState: SessionScrollState?
    private var appliedTopContentInset: CGFloat = 0

    private var isNativeScrollInteractionActive: Bool {
        !measurementCommitGate.allowsGeometryCommit || isExplicitUserScroll
    }

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        let nativeLayout = TranscriptCollectionLayout()
        transcriptLayout = nativeLayout
        super.init(frame: frame, collectionViewLayout: nativeLayout)
        finishInitialization()
    }

    convenience init() {
        self.init(frame: .zero, collectionViewLayout: UICollectionViewLayout())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        measurementCommitTask?.cancel()
        settledMeasurementTask?.cancel()
        disclosureAnchorReleaseTask?.cancel()
    }

    private func finishInitialization() {
        dataSource = self
        delegate = self
        register(
            TranscriptCollectionCell.self,
            forCellWithReuseIdentifier: TranscriptCollectionCell.reuseIdentifier
        )
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        contentInsetAdjustmentBehavior = .never
        scrollsToTop = false
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
        guard !isDetaching else {
            super.layoutSubviews()
            return
        }

        let widthChanged = bounds.width > 0
            && abs(lastViewportSize.width - bounds.width) > 0.5
        if widthChanged {
            let preservation = capturePreservationTarget()
            if activateMeasurementCacheIfNeeded() {
                applyGeometry(
                    makeVirtualLayout(),
                    preservation: preservation,
                    reloadItems: false
                )
            }
        }
        lastViewportSize = bounds.size
        super.layoutSubviews()
        applyPendingInitialPositionIfPossible()
        attachVisibleHostingControllers()
        scheduleSettledMeasurementsNearViewport()
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

        let prependedItemCount = reversePrependCount(from: rows, to: newRows)
        if prependedItemCount != nil, isNativeScrollInteractionActive,
           !layoutFingerprintChanged {
            // A page arriving above the viewport changes every following row's
            // document coordinate. Applying that prefix while UIKit owns a pan
            // requires a compensating offset and breaks 1:1 touch tracking, so
            // install the latest page as soon as momentum ends instead.
            deferredRowsDuringScroll = newRows
        } else {
            deferredRowsDuringScroll = nil
            applyRows(
                newRows,
                layoutFingerprintChanged: layoutFingerprintChanged,
                prependedItemCount: prependedItemCount
            )
        }

        if newScrollCommand != scrollCommand {
            scrollCommand = newScrollCommand
            lockedRestoreDistance = nil
            followsLatest = true
            scrollToBottom()
        }

        scheduleSettledMeasurementsNearViewport()
        startPendingSendAnimationIfPossible()
        checkForHistoryPrefetch()
        // UICollectionView commits a pending reload/invalidation inside
        // super.layoutSubviews(). Applying the restored offset here can be
        // clamped back to the old content size by that later layout pass.
        // layoutSubviews applies the initial position immediately after the
        // native geometry transaction has completed.
        setNeedsLayout()
    }

    func prepareForDismantle() {
        republishLastStableScrollState()
        isDetaching = true
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        settledMeasurementTask?.cancel()
        cancelSettledMeasurementPipeline()
        clearPooledMeasuredHosts()
        for case let cell as TranscriptCollectionCell in visibleCells {
            cell.detachHostingController()
        }
    }

    // MARK: UICollectionViewDataSource

    func numberOfSections(in collectionView: UICollectionView) -> Int { 1 }

    func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        rows.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let reusable = dequeueReusableCell(
            withReuseIdentifier: TranscriptCollectionCell.reuseIdentifier,
            for: indexPath
        )
        guard let cell = reusable as? TranscriptCollectionCell,
              rows.indices.contains(indexPath.item) else { return reusable }
        configure(cell, for: rows[indexPath.item])
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? TranscriptCollectionCell else { return }
        cell.installHostingController(in: owningViewController)
        if virtualLayout.heights.indices.contains(indexPath.item),
           rows.indices.contains(indexPath.item) {
            let row = rows[indexPath.item]
            cell.updateExpectedHeight(
                virtualLayout.heights[indexPath.item],
                isAuthoritative: hasAuthoritativeHeight(for: row.layoutKey)
            )
            scheduleSettledMeasurementIfNeeded(for: row, prioritized: true)
        }
        startPendingSendAnimationIfPossible()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        (cell as? TranscriptCollectionCell)?.detachHostingController()
    }

    // MARK: UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        measurementCommitGate.draggingDidBegin()
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        isExplicitUserScroll = false
        // A coalesced report queued just before UIKit began tracking must not
        // land one turn later and compensate against the now-moving finger.
        measurementCommitTask?.cancel()
        measurementCommitTask = nil
        settledMeasurementTask?.cancel()
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        cancelDisclosureViewportAnchor()
        lockedRestoreDistance = nil
        isExplicitUserScroll = true
        return true
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        isExplicitUserScroll = false
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isDetaching else { return }
        let previousDistance = lastDistanceFromBottom
        let distance = currentDistanceFromBottom()
        lastDistanceFromBottom = distance

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
            // Match macOS scrollWheel(with:): the last intentional viewport
            // is persisted on every native user-scroll update. Waiting for
            // drag/deceleration completion loses the destination if the view
            // is removed while momentum is still active.
            emitViewportSnapshot()
        }
        scheduleSettledMeasurementsNearViewport()
        checkForHistoryPrefetch()
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        measurementCommitGate.draggingDidEnd(willDecelerate: decelerate)
        if !decelerate { finishNativeScrollInteraction() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        measurementCommitGate.interactionDidEnd()
        finishNativeScrollInteraction()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        finishNativeScrollInteraction()
    }

    private func finishNativeScrollInteraction() {
        measurementCommitGate.interactionDidEnd()
        applyDeferredRowsIfNeeded()
        commitPendingMeasurements()
        scheduleSettledMeasurementsNearViewport()
        startSettledMeasurementPipelineIfNeeded()
        emitViewportSnapshot()
        checkForHistoryPrefetch()
    }

    private func applyDeferredRowsIfNeeded() {
        guard let deferredRowsDuringScroll else { return }
        self.deferredRowsDuringScroll = nil
        applyRows(
            deferredRowsDuringScroll,
            layoutFingerprintChanged: false,
            prependedItemCount: reversePrependCount(from: rows, to: deferredRowsDuringScroll)
        )
    }

    private func applyRows(
        _ newRows: [TranscriptVirtualRow],
        layoutFingerprintChanged: Bool,
        prependedItemCount: Int?
    ) {
        let geometryChanged = rows.count != newRows.count
            || zip(rows, newRows).contains { old, new in
                old.id != new.id
                    || old.estimatedHeight != new.estimatedHeight
                    || old.measurementRevision != new.measurementRevision
            }
        let identifiersChanged = rows.map(\.id) != newRows.map(\.id)
        let previousRowsByKey = rowByKey
        let preservation = capturePreservationTarget()

        if geometryChanged || layoutFingerprintChanged {
            transferActiveHeightIfNeeded(from: rows, to: newRows)
            invalidateChangedMeasurements(
                previousRowsByKey: previousRowsByKey,
                newRows: newRows
            )
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            evictPooledHosts(previousRowsByKey: previousRowsByKey)
            _ = activateMeasurementCacheIfNeeded()
            installExactSpacerMeasurements()
            applyGeometry(
                makeVirtualLayout(),
                preservation: preservation,
                reloadItems: identifiersChanged,
                prependedItemCount: prependedItemCount
            )
            if !identifiersChanged {
                if layoutFingerprintChanged {
                    refreshVisibleRootViews()
                } else {
                    refreshChangedVisibleRootViews(previousRowsByKey: previousRowsByKey)
                }
            }
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.layoutKey, $0) })
            evictPooledHosts(previousRowsByKey: previousRowsByKey)
            refreshChangedVisibleRootViews(previousRowsByKey: previousRowsByKey)
        }
    }

    // MARK: Native geometry transactions

    private enum PreservationTarget {
        case none
        case bottom
        case row(key: String, frameTop: CGFloat)
        case absoluteViewport
    }

    private func capturePreservationTarget() -> PreservationTarget {
        guard initialPositionApplied, !virtualLayout.isEmpty else { return .none }
        if disclosureViewportAnchor != nil { return .absoluteViewport }
        // A bottom restore is initially laid out from cached and estimated
        // heights. Keep its distance at zero while the exact UIKit cell
        // measurements settle, just as macOS preserves the previous bottom
        // distance during its geometry rebuild. Native-scroll measurement
        // commits are gated above, so this cannot fight an active finger.
        if followsLatest && currentDistanceFromBottom() <= Self.atBottomThreshold {
            return .bottom
        }
        let viewportTop = contentOffset.y
        let range = virtualLayout.visibleRange(
            distanceFromBottom: currentDistanceFromBottom(),
            viewportHeight: viewportHeight,
            overscanCount: 0
        )
        let anchorIndex = range.first(where: { index in
            guard virtualLayout.keys.indices.contains(index) else { return false }
            return hasAuthoritativeHeight(for: virtualLayout.keys[index])
        }) ?? range.first
        guard let index = anchorIndex,
              virtualLayout.keys.indices.contains(index) else { return .absoluteViewport }
        return .row(
            key: virtualLayout.keys[index],
            frameTop: TranscriptCollectionLayout.topPadding
                + virtualLayout.topOffsets[index]
                - viewportTop
        )
    }

    private func makeVirtualLayout() -> VirtualTranscriptLayout {
        VirtualTranscriptLayout(
            items: rows.map {
                .init(key: $0.layoutKey, estimatedHeight: $0.estimatedHeight)
            },
            measuredHeights: measurements.heightsByKey,
            spacing: TranscriptCollectionLayout.rowSpacing
        )
    }

    private func applyGeometry(
        _ nextLayout: VirtualTranscriptLayout,
        preservation: PreservationTarget,
        reloadItems: Bool,
        prependedItemCount: Int? = nil
    ) {
        let previousMaximumOffset = viewportGeometry.maximumOffsetY
        virtualLayout = nextLayout

        let nextViewport = VirtualTranscriptViewport(
            contentHeight: max(1, TranscriptCollectionLayout.topPadding + nextLayout.totalHeight),
            viewportHeight: viewportHeight,
            topInset: appliedTopContentInset
        )
        let adjustment: CGFloat
        switch preservation {
        case .none, .absoluteViewport:
            adjustment = 0
        case .bottom:
            adjustment = nextViewport.maximumOffsetY - previousMaximumOffset
        case let .row(key, frameTop):
            if let index = nextLayout.indexByKey[key] {
                let nextTop = TranscriptCollectionLayout.topPadding
                    + nextLayout.topOffsets[index]
                adjustment = nextTop - (contentOffset.y + frameTop)
            } else {
                adjustment = 0
            }
        }

        let barriers = rows.indices.filter { rows[$0].id.isPlanDocument }
        transcriptLayout.setGeometry(
            nextLayout,
            overscanBarriers: barriers,
            contentOffsetAdjustment: adjustment
        )
        if let prependedItemCount, prependedItemCount > 0 {
            // Reverse pagination is a real collection update, not a reload.
            // Existing visible cells therefore keep their SwiftUI hosts,
            // exact heights, and native gesture continuity while UIKit adds
            // the older prefix above them.
            let inserted = (0..<prependedItemCount).map {
                IndexPath(item: $0, section: 0)
            }
            UIView.performWithoutAnimation {
                performBatchUpdates {
                    insertItems(at: inserted)
                }
            }
        } else if reloadItems {
            reloadData()
        }
        updateVisibleExpectedHeights()
        lastDistanceFromBottom = nextViewport.distanceFromBottom(
            offsetY: contentOffset.y + adjustment
        )
    }

    private var viewportHeight: CGFloat { max(0, bounds.height) }

    private var viewportGeometry: VirtualTranscriptViewport {
        VirtualTranscriptViewport(
            contentHeight: max(
                1,
                TranscriptCollectionLayout.topPadding + virtualLayout.totalHeight
            ),
            viewportHeight: viewportHeight,
            topInset: appliedTopContentInset
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

        if let state = pendingInitialState, !state.isAtBottom {
            if state.distanceFromBottom > viewportGeometry.maximumDistanceFromBottom + 0.5,
               hasOlderHistory {
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
        if let preservedDistance, !isTracking, !isDragging, !isDecelerating {
            setDistanceFromBottom(preservedDistance)
        }
        lastDistanceFromBottom = currentDistanceFromBottom()
        setNeedsLayout()
    }

    private func scrollToBottom() {
        lockedRestoreDistance = nil
        setDistanceFromBottom(0)
        emitViewportSnapshot()
    }

    /// A history page is an exact prefix insertion. Detecting that shape lets
    /// UICollectionView preserve all existing cells instead of rebuilding the
    /// viewport with reloadData. Empty initial population intentionally uses
    /// the simpler reload path.
    private func reversePrependCount(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow]
    ) -> Int? {
        guard !oldRows.isEmpty, newRows.count > oldRows.count else { return nil }
        let insertedCount = newRows.count - oldRows.count
        guard zip(oldRows, newRows.dropFirst(insertedCount)).allSatisfy({ old, new in
            old.id == new.id
        }) else { return nil }
        return insertedCount
    }

    // MARK: Measurements and reusable cells

    private var effectiveRowWidth: CGFloat {
        let availableWidth = max(
            1,
            bounds.width - TranscriptCollectionLayout.horizontalPadding * 2
        )
        return min(TranscriptCollectionLayout.maxRowWidth, availableWidth)
    }

    @discardableResult
    private func activateMeasurementCacheIfNeeded() -> Bool {
        guard bounds.width > 0 else { return false }
        let key = SessionMeasurementCacheKey(
            rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
            layoutFingerprint: layoutFingerprint
        )
        guard key != activeMeasurementCacheKey else { return false }

        cancelSettledMeasurementPipeline()
        clearPooledMeasuredHosts()
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

        let provisionalVisibleHeights: [String: CGFloat] = Dictionary(
            uniqueKeysWithValues: visibleTranscriptCells.compactMap { cell in
                guard let representedKey = cell.representedKey,
                      let height = measurements[representedKey] else { return nil }
                return (representedKey, height)
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
        for (visibleKey, height) in provisionalVisibleHeights
        where measurements[visibleKey] == nil {
            measurements.setProvisional(height, for: visibleKey)
        }
        if let restore = pendingInitialState?.virtualTranscript,
           restore.measurementCacheKey == key {
            for (rowKey, height) in restore.rowHeightsByKey where height > 0 {
                guard let row = rowByKey[rowKey],
                      !hasAuthoritativeHeight(for: rowKey) else { continue }
                if row.id.isCacheableSettledRow {
                    guard let settled = restore.settledRowsByKey[rowKey],
                          settled.revision == row.measurementRevision else { continue }
                    // Matching cache key proves the width and layout
                    // fingerprint; matching revision proves the content. That
                    // is the same validity proof the width-keyed cache uses,
                    // so the restored height is exact — re-measuring it on
                    // every reopen was pure first-scroll debt.
                    measurements.setExact(height, for: rowKey)
                    let measured = SessionMeasuredRow(
                        height: height,
                        revision: settled.revision
                    )
                    settledRowHeightSnapshot[rowKey] = measured
                    measurementCaches[key, default: [:]][rowKey] = measured
                } else {
                    measurements.setProvisional(height, for: rowKey)
                }
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
              case let .message(item, waitingOnBackgroundTask: _) = settledActive.content,
              case .assistant = item,
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
        }
    }

    private func configure(
        _ cell: TranscriptCollectionCell,
        for row: TranscriptVirtualRow
    ) {
        let key = row.layoutKey
        cell.onMeasuredHeight = { [weak self] measurement in
            guard let self else { return }
            // A reusable display cell is not an authoritative sizing surface.
            // Settled rows are measured by the fixed-width off-cell host below;
            // only genuinely live/special rows may resize from their mounted
            // presentation subtree.
            if row.id.isCacheableSettledRow,
               self.disclosureViewportAnchor == nil {
                self.scheduleSettledMeasurementIfNeeded(for: row, prioritized: true)
            } else {
                self.recordMeasuredHeight(measurement)
            }
        }
        cell.onPresentationReady = { [weak self] representedKey in
            guard self?.pendingSendAnimationRowKey == representedKey else { return }
            self?.startPendingSendAnimationIfPossible()
        }
        let expectedHeight = virtualLayout.indexByKey[key].flatMap { index in
            virtualLayout.heights.indices.contains(index)
                ? virtualLayout.heights[index]
                : nil
        } ?? row.estimatedHeight
        cell.configure(
            key: key,
            revision: row.measurementRevision,
            rootView: measuredRootView(for: row),
            adoptedController: takePooledMeasuredHost(for: row),
            expectedHeight: expectedHeight,
            hasAuthoritativeExpectedHeight: hasAuthoritativeHeight(for: key),
            parent: owningViewController
        )
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
                    self?.invalidateRenderedHeight(for: key)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key)
        )
    }

    private func invalidateRenderedHeight(for key: String) {
        guard let row = rowByKey[key] else { return }
        guard row.id.isCacheableSettledRow else {
            visibleCell(forKey: key)?.requestContentMeasurement()
            return
        }
        settledMeasurementGenerations[key, default: 0] &+= 1
        measurements.markStale(key)
        pendingMeasurements.removeValue(forKey: key)
        settledRowHeightSnapshot.removeValue(forKey: key)
        if let activeMeasurementCacheKey {
            measurementCaches[activeMeasurementCacheKey]?.removeValue(forKey: key)
        }
        updateVisibleExpectedHeights()
        if disclosureViewportAnchor != nil {
            visibleCell(forKey: key)?.requestContentMeasurement()
        } else {
            scheduleSettledMeasurementIfNeeded(for: row, prioritized: true)
        }
    }

    private func refreshVisibleRootViews() {
        for cell in visibleTranscriptCells {
            guard let key = cell.representedKey,
                  let row = rowByKey[key] else { continue }
            configure(cell, for: row)
        }
    }

    private func refreshChangedVisibleRootViews(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        for cell in visibleTranscriptCells {
            guard let key = cell.representedKey,
                  let row = rowByKey[key],
                  previousRowsByKey[key]?.content != row.content else { continue }
            configure(cell, for: row)
        }
    }

    private func updateVisibleExpectedHeights() {
        for cell in visibleTranscriptCells {
            guard let key = cell.representedKey,
                  let index = virtualLayout.indexByKey[key],
                  virtualLayout.heights.indices.contains(index) else { continue }
            cell.updateExpectedHeight(
                virtualLayout.heights[index],
                isAuthoritative: hasAuthoritativeHeight(for: key)
            )
        }
    }

    private func hasAuthoritativeHeight(for key: String) -> Bool {
        measurements[key] != nil && !measurements.isStale(key)
    }

    private var visibleTranscriptCells: [TranscriptCollectionCell] {
        visibleCells.compactMap { $0 as? TranscriptCollectionCell }
    }

    private func visibleCell(forKey key: String) -> TranscriptCollectionCell? {
        visibleTranscriptCells.first { $0.representedKey == key }
    }

    // MARK: Authoritative settled-row measurement

    /// Measures a pixel window rather than a fixed number of rows. A single
    /// assistant turn can be several screens tall, so row-count overscan alone
    /// does not guarantee that the user/assistant boundary ahead of the finger
    /// has exact geometry before it becomes visible.
    private func scheduleSettledMeasurementsNearViewport() {
        guard initialPositionApplied, viewportHeight > 0,
              !virtualLayout.isEmpty else { return }
        let viewportDocumentTop = max(
            0,
            contentOffset.y - TranscriptCollectionLayout.topPadding
        )
        let buffer = max(800, viewportHeight * 2)
        let lower = max(0, viewportDocumentTop - buffer)
        let upper = min(
            virtualLayout.totalHeight,
            viewportDocumentTop + viewportHeight + buffer
        )
        let expandedHeight = max(1, upper - lower)
        let distance = virtualLayout.distanceFromBottom(
            viewportTop: lower,
            viewportHeight: expandedHeight
        )
        let range = virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: expandedHeight,
            overscanCount: 1
        )
        let viewportCenter = viewportDocumentTop + viewportHeight / 2
        let prioritizedIndices = range.sorted { lhs, rhs in
            let lhsCenter = virtualLayout.topOffsets[lhs] + virtualLayout.heights[lhs] / 2
            let rhsCenter = virtualLayout.topOffsets[rhs] + virtualLayout.heights[rhs] / 2
            return abs(lhsCenter - viewportCenter) < abs(rhsCenter - viewportCenter)
        }
        for index in prioritizedIndices where rows.indices.contains(index) {
            scheduleSettledMeasurementIfNeeded(for: rows[index], prioritized: false)
        }
    }

    private func scheduleSettledMeasurementIfNeeded(
        for row: TranscriptVirtualRow,
        prioritized: Bool
    ) {
        guard row.id.isCacheableSettledRow, bounds.width > 0,
              !hasAuthoritativeHeight(for: row.layoutKey) else { return }
        let signature = measurementSignature(for: row)
        if let pending = pendingMeasurements[row.layoutKey],
           pending.revision == signature.revision,
           pending.rowWidthHalfPoints == signature.rowWidthHalfPoints {
            return
        }
        guard queuedSettledMeasurementSignatures.insert(signature).inserted else { return }
        let request = TranscriptSettledMeasurementRequest(
            signature: signature,
            rootView: measuredRootView(for: row)
        )
        if prioritized {
            settledMeasurementQueue.insert(request, at: 0)
        } else {
            settledMeasurementQueue.append(request)
        }
        startSettledMeasurementPipelineIfNeeded()
    }

    private func startSettledMeasurementPipelineIfNeeded() {
        guard !isNativeScrollInteractionActive,
              settledMeasurementTask == nil,
              !settledMeasurementQueue.isEmpty else { return }
        settledMeasurementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var turnStart = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled, !self.settledMeasurementQueue.isEmpty {
                // Warm-up work never competes with a live finger.
                if self.isTracking || self.isNativeScrollInteractionActive { break }
                // Frame budget: back-to-back row measurements starve event
                // delivery even with yields between rows, because yielded
                // continuations re-enqueue immediately. Once a turn has spent
                // its budget, sleep for roughly a frame so touches and
                // rendering interleave with the remaining warm-up work.
                if CFAbsoluteTimeGetCurrent() - turnStart
                    > Self.settledMeasurementTurnBudget {
                    try? await Task.sleep(for: .milliseconds(8))
                    guard !Task.isCancelled else { break }
                    turnStart = CFAbsoluteTimeGetCurrent()
                    continue
                }
                let request = self.settledMeasurementQueue.removeFirst()
                guard self.accepts(request.signature) else {
                    self.queuedSettledMeasurementSignatures.remove(request.signature)
                    continue
                }
                let height = await self.measureSettledRow(request)
                guard !Task.isCancelled else {
                    self.queuedSettledMeasurementSignatures.remove(request.signature)
                    break
                }
                self.queuedSettledMeasurementSignatures.remove(request.signature)
                if let height, self.accepts(request.signature) {
                    self.recordMeasuredHeight(.init(
                        key: request.signature.key,
                        revision: request.signature.revision,
                        rowWidthHalfPoints: request.signature.rowWidthHalfPoints,
                        height: height
                    ))
                }
                await Task.yield()
            }
            self.settledMeasurementTask = nil
            if !self.isNativeScrollInteractionActive,
               !self.settledMeasurementQueue.isEmpty {
                self.startSettledMeasurementPipelineIfNeeded()
            }
        }
    }

    /// A short-lived host converges at a fixed width offscreen. The measured
    /// height is fed back into the host and must repeat before it is accepted;
    /// this keeps SwiftUI/UIViewRepresentable's provisional fitting passes out
    /// of the exact-height cache.
    private func measureSettledRow(
        _ request: TranscriptSettledMeasurementRequest
    ) async -> CGFloat? {
        guard let parent = owningViewController else { return nil }
        let width = CGFloat(request.signature.rowWidthHalfPoints) / 2
        // Use the same safe-area-free hosting contract as visible cells. The
        // measurer's position in the parent view must not be observable by the
        // row or become part of its cached height.
        let controller = TranscriptContentHostingController(rootView: request.rootView)
        controller.sizingOptions = [.intrinsicContentSize]
        parent.addChild(controller)
        let host = controller.view!
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        host.alpha = 0.01
        host.frame = CGRect(
            x: parent.view.bounds.minX - width - 100,
            y: parent.view.bounds.minY,
            width: width,
            height: 1
        )
        parent.view.addSubview(host)
        controller.didMove(toParent: parent)
        func tearDown() {
            controller.willMove(toParent: nil)
            host.removeFromSuperview()
            controller.removeFromParent()
        }

        var previousHeight: CGFloat?
        for _ in 0..<4 {
            // A touch may land while a giant row is mid-measure. Checking the
            // live tracking state between passes bounds how long one row can
            // hold the main thread once a finger is down; the abandoned row is
            // rescheduled by the next viewport sweep.
            guard !Task.isCancelled, !isTracking,
                  !isNativeScrollInteractionActive else {
                tearDown()
                return nil
            }
            host.invalidateIntrinsicContentSize()
            host.setNeedsLayout()
            host.layoutIfNeeded()
            let measured = controller.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
            guard measured.isFinite, measured > 0 else {
                tearDown()
                return nil
            }
            let height = measured.rounded(.up)
            if let previousHeight, abs(previousHeight - height) <= 0.5 {
                // The converged host is parked, not destroyed: the display
                // path adopts it so the row's SwiftUI tree is built once.
                parkMeasuredHost(controller, for: request.signature)
                return height
            }
            previousHeight = height
            host.frame.size = CGSize(width: width, height: height)
            host.setNeedsLayout()
            host.layoutIfNeeded()
            await Task.yield()
        }
        tearDown()
        return nil
    }

    private func measurementSignature(
        for row: TranscriptVirtualRow
    ) -> TranscriptMeasurementSignature {
        TranscriptMeasurementSignature(
            key: row.layoutKey,
            revision: row.measurementRevision,
            rowWidthHalfPoints: Int((effectiveRowWidth * 2).rounded()),
            contentGeneration: settledMeasurementGenerations[row.layoutKey, default: 0]
        )
    }

    private func signatureMatchesCurrentContent(
        _ signature: TranscriptMeasurementSignature
    ) -> Bool {
        guard let row = rowByKey[signature.key], row.id.isCacheableSettledRow,
              row.measurementRevision == signature.revision,
              settledMeasurementGenerations[signature.key, default: 0]
                == signature.contentGeneration,
              signature.rowWidthHalfPoints
                == Int((effectiveRowWidth * 2).rounded()) else { return false }
        return true
    }

    private func accepts(_ signature: TranscriptMeasurementSignature) -> Bool {
        signatureMatchesCurrentContent(signature)
            && !hasAuthoritativeHeight(for: signature.key)
    }

    // MARK: Measured host pool

    /// Detaches a measurement host from its off-screen slot and parks it for
    /// the display path. The signature makes stale adoption impossible: any
    /// content, revision, width, or generation change produces a different key
    /// and the entry simply ages out of the LRU.
    private func parkMeasuredHost(
        _ controller: TranscriptContentHostingController,
        for signature: TranscriptMeasurementSignature
    ) {
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        if pooledMeasuredHosts[signature] == nil {
            pooledMeasuredHostLRU.append(signature)
        }
        pooledMeasuredHosts[signature] = controller
        while pooledMeasuredHostLRU.count > Self.maxPooledMeasuredHosts {
            let evicted = pooledMeasuredHostLRU.removeFirst()
            pooledMeasuredHosts.removeValue(forKey: evicted)
        }
    }

    private func takePooledMeasuredHost(
        for row: TranscriptVirtualRow
    ) -> TranscriptContentHostingController? {
        let signature = measurementSignature(for: row)
        guard let controller = pooledMeasuredHosts.removeValue(forKey: signature) else {
            return nil
        }
        pooledMeasuredHostLRU.removeAll { $0 == signature }
        guard signatureMatchesCurrentContent(signature) else { return nil }
        return controller
    }

    private func clearPooledMeasuredHosts() {
        pooledMeasuredHosts.removeAll(keepingCapacity: false)
        pooledMeasuredHostLRU.removeAll(keepingCapacity: false)
    }

    /// Row content can change without a revision bump (auxiliary row state).
    /// Any content transition evicts that row's parked host so adoption can
    /// never present stale pixels.
    private func evictPooledHosts(
        previousRowsByKey: [String: TranscriptVirtualRow]
    ) {
        guard !pooledMeasuredHosts.isEmpty else { return }
        let stale = Set(pooledMeasuredHostLRU.filter { signature in
            guard let row = rowByKey[signature.key] else { return true }
            guard let previous = previousRowsByKey[signature.key] else { return false }
            return previous.content != row.content
        })
        guard !stale.isEmpty else { return }
        for signature in stale {
            pooledMeasuredHosts.removeValue(forKey: signature)
        }
        pooledMeasuredHostLRU.removeAll { stale.contains($0) }
    }

    private func cancelSettledMeasurementPipeline() {
        settledMeasurementTask?.cancel()
        settledMeasurementQueue.removeAll(keepingCapacity: true)
        queuedSettledMeasurementSignatures.removeAll(keepingCapacity: true)
    }

    private func recordMeasuredHeight(_ rawMeasurement: TranscriptCellMeasurement) {
        let measurement = TranscriptCellMeasurement(
            key: rawMeasurement.key,
            revision: rawMeasurement.revision,
            rowWidthHalfPoints: rawMeasurement.rowWidthHalfPoints,
            height: max(1, rawMeasurement.height.rounded(.up))
        )
        guard accepts(measurement) else { return }
        let needsCommit = pendingMeasurements[measurement.key].map {
            $0.revision != measurement.revision
                || $0.rowWidthHalfPoints != measurement.rowWidthHalfPoints
                || abs($0.height - measurement.height) > 0.5
        } ?? measurements.needsCommit(measurement.height, for: measurement.key)
        guard needsCommit else { return }
        pendingMeasurements[measurement.key] = measurement

        // Settled rows are normally exact before they enter the viewport. If
        // a fallback measurement does arrive during native touch tracking,
        // retain it but do not mutate UICollectionView geometry until the
        // gesture and its momentum have ended.
        if isNativeScrollInteractionActive { return }

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

    /// Coalesces authoritative heights into one native layout transaction.
    /// Touch tracking is a hard geometry barrier: reports collected during a
    /// pan or deceleration remain queued and are committed once UIKit finishes
    /// the interaction, so content-offset compensation cannot oppose a finger.
    private func commitPendingMeasurements() {
        measurementCommitTask = nil
        guard !isNativeScrollInteractionActive else { return }
        let pending = pendingMeasurements
        pendingMeasurements.removeAll(keepingCapacity: true)
        var committedHeights: [String: CGFloat] = [:]
        for (key, measurement) in pending {
            // A row revision or width cache can change during the coalescing
            // yield, so acceptance is intentionally checked a second time.
            guard accepts(measurement),
                  measurements.needsCommit(measurement.height, for: key) else { continue }
            if storeMeasuredHeight(measurement.height, for: key) {
                committedHeights[key] = measurement.height
            }
        }
        guard !committedHeights.isEmpty else { return }

        var nextLayout = virtualLayout
        for (key, height) in committedHeights {
            guard let updated = nextLayout.updatingHeight(forKey: key, to: height) else {
                nextLayout = makeVirtualLayout()
                break
            }
            nextLayout = updated
        }
        applyGeometry(
            nextLayout,
            preservation: capturePreservationTarget(),
            reloadItems: false
        )
    }

    private func accepts(_ measurement: TranscriptCellMeasurement) -> Bool {
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
                revision: row.measurementRevision
            )
            settledRowHeightSnapshot[key] = measurement
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey, default: [:]][key] = measurement
            }
        }
        return heightChanged
    }

    // MARK: Stable state and pagination

    private func checkForHistoryPrefetch(force: Bool = false) {
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
        // UIKit can reset collection geometry as the representable leaves its
        // window. As on macOS, teardown may refresh measurement caches but it
        // must never replace the last user-authored coordinate by sampling
        // that transient native state.
        state.measurementCaches = measurementCaches
        state.measurementCacheLRU = measurementCacheLRU
        state.virtualTranscript = currentVirtualRestoreState()
        lastStableScrollState = state
        onViewportChange?(state)
    }

    private func currentVirtualRestoreState() -> SessionVirtualTranscriptRestoreState {
        let indices = visibleTranscriptCells.compactMap { cell -> Int? in
            guard let key = cell.representedKey else { return nil }
            return virtualLayout.indexByKey[key]
        }.sorted()
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

    // MARK: Disclosure and send presentation

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
        let anchor = DisclosureViewportAnchor(id: UUID())
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
              let cell = visibleCell(forKey: rowKey),
              cell.isPresentationReady else { return }
        let bottomSpacerHeight = rows.last { $0.id == .bottomSpacer }.flatMap { row in
            if case let .bottomSpacer(height) = row.content { height } else { nil }
        } ?? 0
        let sourceY = contentOffset.y + bounds.height - bottomSpacerHeight + 48
        let travel = sourceY - cell.frame.minY
        guard travel > 1 else {
            _ = claimAndClear()
            return
        }
        guard claimAndClear() else { return }

        cell.layer.removeAnimation(forKey: "codevisor.user-send")
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
        cell.layer.add(group, forKey: "codevisor.user-send")
    }

    private var owningViewController: UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    private func attachVisibleHostingControllers() {
        guard let owningViewController else { return }
        for cell in visibleTranscriptCells {
            cell.installHostingController(in: owningViewController)
        }
    }
}
