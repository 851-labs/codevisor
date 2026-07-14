import AppKit
import SwiftUI
import CodevisorCore

/// Stable rows consumed by the native transcript virtualizer. Message rows
/// carry immutable settled snapshots; the active row reads the controller from
/// its own hosting view so token flushes never rebuild the row list.
struct TranscriptVirtualRow: Identifiable, Equatable {
    enum ID: Hashable {
        case message(UUID)
        case active
        case setup
        case optimistic
        case backgroundTask
        case error
        case statusError
        case bottomSpacer

        var layoutKey: String {
            switch self {
            case let .message(id): "message:\(id.uuidString)"
            case .active: "special:active"
            case .setup: "special:setup"
            case .optimistic: "special:optimistic"
            case .backgroundTask: "special:background"
            case .error: "special:error"
            case .statusError: "special:status-error"
            case .bottomSpacer: "special:bottom-spacer"
            }
        }

        var messageID: UUID? {
            guard case let .message(id) = self else { return nil }
            return id
        }
    }

    enum Content: Equatable {
        case message(ConversationItem, waitingOnBackgroundTask: String?)
        case active
        case setup([SessionSetupPhase])
        case optimistic(UserMessage, showsStartingAgent: Bool)
        case backgroundTask(String)
        case error(String)
        case bottomSpacer(CGFloat)
    }

    let id: ID
    let content: Content
    let estimatedHeight: CGFloat
    /// Cheap content fingerprint used to reject a stale measured height.
    let measurementRevision: Int

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
    }
}

struct TranscriptScrollCommand: Equatable {
    var token = 0
}

/// SwiftUI boundary around the AppKit scroll view. All high-frequency geometry
/// stays inside AppKit; SwiftUI receives only boundary transitions and a tiny
/// observation-ignored viewport snapshot.
struct NativeTranscriptView: NSViewRepresentable {
    let rows: [TranscriptVirtualRow]
    let initialState: SessionScrollState?
    let followsLatest: Bool
    let hasOlderHistory: Bool
    let layoutFingerprint: Int
    let scrollCommand: TranscriptScrollCommand
    let rowContent: @MainActor (TranscriptVirtualRow) -> AnyView
    let onViewportChange: @MainActor (SessionScrollState) -> Void
    let onBottomStateChange: @MainActor (Bool) -> Void
    let onFollowStateChange: @MainActor (Bool) -> Void
    let onNearTop: @MainActor () -> Void

    func makeNSView(context: Context) -> VirtualizedTranscriptScrollView {
        let view = VirtualizedTranscriptScrollView()
        view.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop
        )
        return view
    }

    func updateNSView(_ nsView: VirtualizedTranscriptScrollView, context: Context) {
        nsView.configure(
            rows: rows,
            initialState: initialState,
            followsLatest: followsLatest,
            hasOlderHistory: hasOlderHistory,
            layoutFingerprint: layoutFingerprint,
            scrollCommand: scrollCommand,
            rowContent: rowContent,
            onViewportChange: onViewportChange,
            onBottomStateChange: onBottomStateChange,
            onFollowStateChange: onFollowStateChange,
            onNearTop: onNearTop
        )
    }

    static func dismantleNSView(_ nsView: VirtualizedTranscriptScrollView, coordinator: Void) {
        nsView.persistViewport()
    }
}

private final class FlippedTranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class TranscriptContentHostingController: NSHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override func viewDidLayout() {
        super.viewDidLayout()
        measureAndReportHeight()
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    private func measureAndReportHeight() {
        let proposedSize = CGSize(
            width: max(1, view.bounds.width),
            height: .greatestFiniteMagnitude
        )
        let height = max(1, sizeThatFits(in: proposedSize).height.rounded(.up))
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }

    func invalidateContentSize() {
        view.invalidateIntrinsicContentSize()
        view.needsLayout = true
        view.superview?.needsLayout = true
        // SwiftUI observation can update content entirely inside this hosting
        // controller without causing AppKit to lay the explicitly-sized outer
        // wrapper out again. Measure after SwiftUI commits that update so the
        // virtualizer never keeps positioning later rows from a stale height.
        guard pendingMeasurementTask == nil else { return }
        pendingMeasurementTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingMeasurementTask = nil
            self.view.layoutSubtreeIfNeeded()
            self.measureAndReportHeight()
        }
    }

    func resetReportedHeight() {
        lastReportedHeight = 0
    }
}

/// A mounted row's SwiftUI content owns its natural height. The virtualizer
/// supplies only the row's top position and width, then observes the hosting
/// view's laid-out height to move later rows. Estimated outer heights are never
/// imposed back onto mounted content.
@MainActor
private final class TranscriptRowHost: NSView {
    private let contentController = TranscriptContentHostingController(rootView: AnyView(EmptyView()))
    private var contentHost: NSView { contentController.view }
    private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(equalToConstant: 1)
    private lazy var contentHeightConstraint = contentHost.heightAnchor.constraint(equalToConstant: 1)
    var onHeightChange: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentController.sizingOptions = [.intrinsicContentSize]
        contentHost.setContentHuggingPriority(.required, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentWidthConstraint,
            contentHeightConstraint,
        ])
        contentController.onLaidOutHeightChange = { [weak self] height in
            self?.contentHeightDidChange(height)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        let width = max(1, bounds.width)
        if abs(contentWidthConstraint.constant - width) > 0.5 {
            contentWidthConstraint.constant = width
            contentController.invalidateContentSize()
        }
        super.layout()
    }

    var rootView: AnyView {
        get { contentController.rootView }
        set {
            contentController.rootView = newValue
            contentController.invalidateContentSize()
        }
    }

    func prepareForMountedRow() {
        contentController.resetReportedHeight()
    }

    func requestContentMeasurement() {
        contentController.invalidateContentSize()
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        // SwiftUI can lay out beyond this wrapper's estimated height before the
        // virtualizer consumes the measurement. Keep the AppKit wrapper in sync
        // immediately so its visible content and pointer hit-test bounds never
        // disagree during that window.
        if abs(contentHeightConstraint.constant - height) > 0.5 {
            contentHeightConstraint.constant = height
        }
        if abs(frame.height - height) > 0.5 {
            var nextFrame = frame
            nextFrame.size.height = height
            frame = nextFrame
        }
        onHeightChange?(height)
    }
}

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
    private static let atBottomThreshold: CGFloat = 2
    private static let maxMeasurementCacheCount = 3

    private let transcriptDocumentView = FlippedTranscriptDocumentView()
    private var rows: [TranscriptVirtualRow] = []
    private var rowByKey: [String: TranscriptVirtualRow] = [:]
    private var virtualLayout = VirtualTranscriptLayout(items: [], measuredHeights: [:], spacing: rowSpacing)
    private var measuredHeights: [String: CGFloat] = [:]
    /// Message-only height snapshots shared copy-on-write with scroll state.
    /// Position updates can therefore publish synchronously without walking
    /// the transcript or copying these dictionaries on every trackpad frame.
    private var messageHeightSnapshot: [UUID: SessionMeasuredRow] = [:]
    private var measurementCaches: [
        SessionMeasurementCacheKey: [UUID: SessionMeasuredRow]
    ] = [:]
    private var measurementCacheLRU: [SessionMeasurementCacheKey] = []
    private var activeMeasurementCacheKey: SessionMeasurementCacheKey?
    private var layoutFingerprint = 0

    private var mountedHosts: [String: TranscriptRowHost] = [:]
    private var recycledHosts: [TranscriptRowHost] = []
    private var rowContent: ((TranscriptVirtualRow) -> AnyView)?
    private var pendingMeasuredHeights: [String: CGFloat] = [:]
    private var measurementCommitTask: Task<Void, Never>?
    /// A scrollbar-knob drag can cross dozens of virtual windows in a single
    /// frame. Mount only the latest one at a display-friendly cadence instead
    /// of making AppKit wait for every intermediate SwiftUI host tree.
    private var knobDragMountTask: Task<Void, Never>?

    private struct DisclosureViewportAnchor {
        let id: UUID
        let viewportTop: CGFloat
    }
    private var disclosureViewportAnchor: DisclosureViewportAnchor?
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
    private var scrollCommand = TranscriptScrollCommand()
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

    private var onViewportChange: ((SessionScrollState) -> Void)?
    private var onBottomStateChange: ((Bool) -> Void)?
    private var onFollowStateChange: ((Bool) -> Void)?
    private var onNearTop: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        backgroundColor = .clear
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentView.postsBoundsChangedNotifications = true
        documentView = transcriptDocumentView

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportDidScroll() }
        }
        liveScrollObservers = [
            NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: self,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.cancelDisclosureViewportAnchor()
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
                MainActor.assumeIsolated {
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        measurementCommitTask?.cancel()
        knobDragMountTask?.cancel()
        disclosureAnchorReleaseTask?.cancel()
        if let boundsObserver {
            NotificationCenter.default.removeObserver(boundsObserver)
        }
        for observer in liveScrollObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // AppKit may already have reset the clip bounds before this callback.
        // Re-publish the last intentional position with fresh measurement
        // caches; never sample teardown geometry here.
        if newWindow == nil, window != nil {
            republishLastStableScrollState()
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
        if abs(width - lastViewportWidth) > 0.5 {
            lastViewportWidth = width
            _ = activateMeasurementCacheIfNeeded()
            rebuildDocumentGeometry()
        } else {
            applyPendingInitialPositionIfPossible()
            updateMountedRows()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        cancelDisclosureViewportAnchor()
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
        cancelDisclosureViewportAnchor()
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
        layoutFingerprint newLayoutFingerprint: Int,
        scrollCommand newScrollCommand: TranscriptScrollCommand,
        rowContent newRowContent: @escaping (TranscriptVirtualRow) -> AnyView,
        onViewportChange: @escaping (SessionScrollState) -> Void,
        onBottomStateChange: @escaping (Bool) -> Void,
        onFollowStateChange: @escaping (Bool) -> Void,
        onNearTop: @escaping () -> Void
    ) {
        self.rowContent = newRowContent
        self.onViewportChange = onViewportChange
        self.onBottomStateChange = onBottomStateChange
        self.onFollowStateChange = onFollowStateChange
        self.onNearTop = onNearTop
        hasOlderHistory = newHasOlderHistory

        let layoutFingerprintChanged = layoutFingerprint != newLayoutFingerprint
        layoutFingerprint = newLayoutFingerprint

        if !initialPositionConfigured {
            initialPositionConfigured = true
            pendingInitialState = initialState
            lastStableScrollState = initialState
            if let initialState, !initialState.isAtBottom {
                lockedRestoreDistance = initialState.distanceFromBottom
                followsLatest = false
            } else {
                followsLatest = newFollowsLatest
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
        let geometryChanged = rows.count != newRows.count || zip(rows, newRows).contains { old, new in
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
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id.layoutKey, $0) })
            _ = activateMeasurementCacheIfNeeded()
            for row in newRows {
                if case let .bottomSpacer(height) = row.content {
                    measuredHeights[row.id.layoutKey] = height
                }
            }
            refreshMountedRootViews()
            rebuildDocumentGeometry()
        } else {
            rows = newRows
            rowByKey = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id.layoutKey, $0) })
            refreshChangedMountedRootViews(previousRowsByKey: previousRowsByKey)
        }

        if newScrollCommand != scrollCommand {
            scrollCommand = newScrollCommand
            lockedRestoreDistance = nil
            followsLatest = true
            scrollToBottom()
        }

        applyPendingInitialPositionIfPossible()
        checkForHistoryPrefetch()
    }

    func persistViewport() {
        republishLastStableScrollState()
    }

    private func transferActiveHeightIfNeeded(
        from oldRows: [TranscriptVirtualRow],
        to newRows: [TranscriptVirtualRow]
    ) {
        guard oldRows.contains(where: { $0.id == .active }),
              let activeHeight = measuredHeights[TranscriptVirtualRow.ID.active.layoutKey],
              !newRows.contains(where: { $0.id == .active }) else { return }
        let oldMessageIDs = Set(oldRows.compactMap(\.id.messageID))
        guard let settledActive = newRows.last(where: { row in
            guard let id = row.id.messageID else { return false }
            return !oldMessageIDs.contains(id)
        }), measuredHeights[settledActive.id.layoutKey] == nil else { return }
        measuredHeights[settledActive.id.layoutKey] = activeHeight
        if let id = settledActive.id.messageID {
            let measurement = SessionMeasuredRow(
                height: activeHeight,
                revision: settledActive.measurementRevision
            )
            messageHeightSnapshot[id] = measurement
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey, default: [:]][id] = measurement
            }
        }
    }

    private func invalidateChangedMeasurements(
        previousRowsByKey: [String: TranscriptVirtualRow],
        newRows: [TranscriptVirtualRow]
    ) {
        for row in newRows {
            guard let id = row.id.messageID,
                  let previous = previousRowsByKey[row.id.layoutKey],
                  previous.measurementRevision != row.measurementRevision else { continue }
            measuredHeights.removeValue(forKey: row.id.layoutKey)
            messageHeightSnapshot.removeValue(forKey: id)
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey]?.removeValue(forKey: id)
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
        // written into the new width's cache.
        let provisionalMountedHeights = Dictionary(uniqueKeysWithValues: mountedHosts.keys.compactMap { key in
            measuredHeights[key].map { (key, $0) }
        })
        measuredHeights.removeAll(keepingCapacity: true)
        let cached = measurementCaches[key] ?? [:]
        var valid: [UUID: SessionMeasuredRow] = [:]
        valid.reserveCapacity(cached.count)
        for row in rows {
            guard let id = row.id.messageID,
                  let measurement = cached[id],
                  measurement.revision == row.measurementRevision,
                  measurement.height > 0 else { continue }
            valid[id] = measurement
            measuredHeights[row.id.layoutKey] = measurement.height
        }
        messageHeightSnapshot = valid
        measurementCaches[key] = valid
        for row in rows {
            if case let .bottomSpacer(height) = row.content {
                measuredHeights[row.id.layoutKey] = height
            }
        }
        for (key, height) in provisionalMountedHeights where measuredHeights[key] == nil {
            measuredHeights[key] = height
        }
        // ChatGPT restores the exact height map that produced its saved
        // coordinate before mounting the saved rendered window. Apply it only
        // when the width/typography key still matches; current measurements
        // replace these provisional values as soon as the hosts lay out.
        if let restore = pendingInitialState?.virtualTranscript,
           restore.measurementCacheKey == key {
            for (rowKey, height) in restore.rowHeightsByKey
            where rowByKey[rowKey] != nil && height > 0 {
                measuredHeights[rowKey] = height
            }
        }
        return true
    }

    private func rebuildDocumentGeometry() {
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
        let followsStreamingLatest = followsLatest && rows.contains { $0.id == .active }
        let visibleAnchorKey: String?
        if !followsStreamingLatest, let previousDistance, !previousLayout.isEmpty {
            let visibleRange = previousLayout.visibleRange(
                distanceFromBottom: previousDistance,
                viewportHeight: contentView.bounds.height,
                overscanCount: 0
            )
            // Match ChatGPT's compensation rule: prefer a visible row whose
            // height is already measured, then fall back to the first visible
            // key. Estimates must not become an anchor when an exact row is
            // available in the same viewport.
            visibleAnchorKey = visibleRange.compactMap { index -> String? in
                guard previousLayout.keys.indices.contains(index) else { return nil }
                let key = previousLayout.keys[index]
                return measuredHeights[key] == nil ? nil : key
            }.first ?? visibleRange.first.flatMap { index in
                previousLayout.keys.indices.contains(index) ? previousLayout.keys[index] : nil
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
            virtualLayout = VirtualTranscriptLayout(
                items: rows.map {
                    .init(key: $0.id.layoutKey, estimatedHeight: $0.estimatedHeight)
                },
                measuredHeights: measuredHeights,
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
                height: max(1, Self.topPadding + virtualLayout.totalHeight)
            )
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
            // A delayed bounds notification after this transaction sees the
            // final canonical distance, not the transient pre-compensation one.
            lastDistanceFromBottom = currentDistanceFromBottom()
        }
        updateMountedRows(rangeOverride: initialRestoreRange)
    }

    private func applyPendingInitialPositionIfPossible() {
        guard !initialPositionApplied, contentView.bounds.height > 0 else { return }

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
            followsLatest = false
            publishBottomState(currentDistanceFromBottom() <= Self.atBottomThreshold)
        } else {
            lockedRestoreDistance = nil
            setDistanceFromBottom(0)
            followsLatest = true
        }

        initialPositionApplied = true
        pendingInitialState = nil
        updateMountedRows(rangeOverride: restoredRange)
        // A saved target is already the authoritative persisted state. Do not
        // replace it with a clamped/intermediate first-layout coordinate.
        if lastStableScrollState == nil || followsLatest {
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
        lockedRestoreDistance = nil
        setDistanceFromBottom(0)
        updateMountedRows()
        emitViewportSnapshot()
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
        let isRecentUserMovement = isHandlingUserInput || isLiveScrolling
            || ProcessInfo.processInfo.systemUptime <= userInputDeadline
        // Moving away from the end is authoritative intent. Layout-driven
        // position changes are wrapped in `isApplyingPosition`; requiring a
        // wheel callback here let an asynchronously-delivered bounds change
        // leave follow enabled long enough to snap the viewport back down.
        if !isApplyingPosition, distance > previousDistance + 0.5, followsLatest {
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
        let oldestKey = rows.first?.id.layoutKey
        guard force || oldestKey != lastPrefetchOldestKey else { return }
        lastPrefetchOldestKey = oldestKey
        onNearTop?()
    }

    private func updateMountedRows(rangeOverride: Range<Int>? = nil) {
        guard initialPositionApplied || contentView.bounds.height > 0 else { return }
        let distance = currentDistanceFromBottom()
        let targetRange = rangeOverride ?? virtualLayout.visibleRange(
            distanceFromBottom: distance,
            viewportHeight: contentView.bounds.height,
            overscanCount: Self.overscanCount
        )
        // Preserve a rendered window that already contains the target. This is
        // ChatGPT's rendered-range containment rule: height changes inside a
        // visible turn must not recycle that turn halfway through its update.
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
                host.rootView = measuredRootView(for: row)
                transcriptDocumentView.addSubview(host)
                mountedHosts[key] = host
                position(host: host, at: index)
            }
        }
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
        let key = row.id.layoutKey
        return AnyView(
            rowContent(row)
                .environment(\.transcriptPerformAnchoredDisclosureChange) { [weak self] change in
                    self?.performAnchoredDisclosureChange(in: key, change: change) ?? change()
                }
                .environment(\.transcriptInvalidateRowMeasurement) { [weak self] in
                    self?.mountedHosts[key]?.requestContentMeasurement()
                }
                // The hosting view's measured height is rounded up to keep
                // row geometry stable. Pin the SwiftUI root to the top so any
                // sub-point rounding slack stays below the message instead of
                // recentering it when a disclosure changes the row height.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .id(key)
        )
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
        let anchor = DisclosureViewportAnchor(
            id: UUID(),
            viewportTop: contentView.bounds.minY
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

    private func recordMeasuredHeight(_ rawHeight: CGFloat, for key: String) {
        let height = max(1, rawHeight.rounded(.up))
        guard rowByKey[key] != nil else { return }
        let current = pendingMeasuredHeights[key] ?? measuredHeights[key] ?? 0
        guard abs(current - height) > 0.5 else { return }
        pendingMeasuredHeights[key] = height

        // A streaming active row needs its latest height in the same update;
        // ordinary/history rows are committed together after SwiftUI finishes
        // the current layout pass so hosts never use mixed geometry snapshots.
        if key == TranscriptVirtualRow.ID.active.layoutKey, !inLiveResize {
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
        var changed = false
        for (key, height) in pending {
            guard rowByKey[key] != nil,
                  abs((measuredHeights[key] ?? 0) - height) > 0.5 else { continue }
            storeMeasuredHeight(height, for: key)
            changed = true
        }
        if changed {
            rebuildDocumentGeometry()
        }
    }

    private func storeMeasuredHeight(_ height: CGFloat, for key: String) {
        measuredHeights[key] = height
        if let row = rowByKey[key], let id = row.id.messageID {
            let measurement = SessionMeasuredRow(
                height: height,
                revision: row.measurementRevision
            )
            messageHeightSnapshot[id] = measurement
            if let activeMeasurementCacheKey {
                measurementCaches[activeMeasurementCacheKey, default: [:]][id] = measurement
            }
        }
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
            y: Self.topPadding + virtualLayout.topOffsets[index],
            width: rowWidth,
            height: virtualLayout.heights[index]
        )
        if host.frame != frame {
            host.frame = frame
        }
    }

    private func emitViewportSnapshot() {
        guard !isDetaching, initialPositionConfigured,
              contentView.bounds.height > 0 else { return }
        let distance = currentDistanceFromBottom()
        let atBottom = distance <= Self.atBottomThreshold
        publishBottomState(atBottom)
        let state = SessionScrollState(
            distanceFromBottom: distance,
            measurementCaches: measurementCaches,
            measurementCacheLRU: measurementCacheLRU,
            virtualTranscript: currentVirtualRestoreState()
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
                  virtualLayout.keys.indices.contains(first) else { return nil }
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
            rowHeightsByKey: measuredHeights,
            renderedWindow: renderedWindow
        )
    }
}
