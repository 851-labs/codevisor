import CodevisorCore
import CodevisorUI
import QuartzCore
import StreamMarkdown
import SwiftUI
import TranscriptKit
import UIKit

@MainActor
final class VirtualizedTranscriptScrollView: UIScrollView, UIScrollViewDelegate {
  static let rowSpacing: CGFloat = 20
  static let topPadding: CGFloat = 12
  static let horizontalPadding: CGFloat = 16
  static let maxRowWidth: CGFloat = 832
  static let initialRunwayViewportCount: CGFloat = 1.5
  static let atBottomThreshold: CGFloat = 2
  let canvasView = UIView()
  let surfaceController = TranscriptSurfaceController()
  let paginationLoadingIndicator = UIActivityIndicatorView(style: .medium)
  weak var hostingParent: UIViewController?

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
  var receivedProjectionRevision: UInt64?
  var appliedProjectionRevision: UInt64?
  var activeRowsVersion: TranscriptRowSetRevision?

  var mountedHosts: [String: TranscriptRowHost] = [:]
  let parkedHosts = TranscriptParkedHosts()
  let virtualWindowPolicy = TranscriptVirtualWindowPolicy()
  var windowPlanner: TranscriptWindowPlanner {
    TranscriptWindowPlanner(
      policy: virtualWindowPolicy,
      initialRunwayViewportCount: Self.initialRunwayViewportCount
    )
  }
  var lastObservedContentOffsetY: CGFloat?
  var remainingMountsThisFrame = 2
  var rowContent: ((TranscriptVirtualRow) -> AnyView)?
  var openMarkdownLink: ((URL) -> Bool)?
  var markdownImageActions: MarkdownImageActions?
  var pendingMeasurements: [String: TranscriptRowMeasurement] = [:]
  var measurementCommitTask: Task<Void, Never>?
  weak var sessionController: SessionController?
  var presentationFrameDriverToken: TranscriptFrameDriverToken?
  var presentationDisplayLink: CADisplayLink?
  var deferredRowsDuringScroll: [TranscriptVirtualRow]?
  var deferredActiveRowsRange: Range<Int>?
  var deferredProjectionRevision: UInt64?

  struct DisclosureViewportAnchor {
    let id: UUID
    let viewportTop: CGFloat
  }

  var disclosureViewportAnchor: DisclosureViewportAnchor?
  var disclosureAnchorReleaseTask: Task<Void, Never>?

  var pendingInitialState: SessionScrollState?
  var isAwaitingWarmProjection = false
  var hasReceivedScrollCommandForAttachment = false
  var hasOlderHistory = false
  var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
  var olderHistoryPresentationTarget: TranscriptPaginationPresentationTarget?
  var isLoadingInitialHistory = false
  var isPreparingInitialProjection = true
  var isActiveProjectionPending = false
  var isAwaitingFirstActiveProjection = false
  var deferredActivePlaceholderKey: String?
  var scrollCommand = TranscriptScrollCommand()
  let sendTransitions = TranscriptSendTransitions<VirtualizedTranscriptScrollView>()
  var sendAnimationSourceFrame: CGRect?
  var isSendTransitionCleanupScheduled = false
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
  var onInitialPresentationReady: (() -> Void)?
  var applicationObserver: NSObjectProtocol?

  var isNativeScrollInteractionActive: Bool {
    isTracking || isDragging || isDecelerating || isExplicitUserScroll
  }
  var frameBudget: TranscriptFrameBudget {
    TranscriptFrameBudget(
      maximumFramesPerSecond: window?.screen.maximumFramesPerSecond ?? 60,
      isInteracting: true
    )
  }
  var maximumMountsPerFrame: Int { frameBudget.mountsPerFrame }
  var mountWorkBudget: CFTimeInterval { frameBudget.workBudget }

  override init(frame: CGRect) {
    super.init(frame: frame)
    sendTransitions.adapter = self
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
    topEdgeEffect.style = .soft
    scrollsToTop = false
    canvasView.alpha = 0
    canvasView.accessibilityElementsHidden = true
    isScrollEnabled = false
    applicationObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Self.onMain { [weak self] in self?.sendTransitions.interrupt() }
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

  isolated deinit {
    presentationDisplayLink?.invalidate()
    measurementCommitTask?.cancel()
    disclosureAnchorReleaseTask?.cancel()
    if let applicationObserver {
      NotificationCenter.default.removeObserver(applicationObserver)
    }
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateTopContentInsetIfNeeded()
  }

  override func willMove(toWindow newWindow: UIWindow?) {
    if newWindow == nil, window != nil {
      emitViewportSnapshot()
    }
    super.willMove(toWindow: newWindow)
  }

  override func didMoveToWindow() {
    if window == nil, superview != nil {
      republishLastStableScrollState()
      sendTransitions.interrupt()
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
      parkedHosts.removeAll()
      _ = activateMeasurementCacheIfNeeded()
      refreshMountedRootViews()
      rebuildDocumentGeometry()
    } else {
      applyPendingInitialPositionIfPossible()
      updateMountedRows()
    }
    if resizeAdjustment == .pinToBottom {
      setDistanceFromBottom(0, synchronizesWithActiveLayoutAnimation: true)
      updateMountedRows()
    } else if heightChanged, initialPositionApplied {
      lastDistanceFromBottom = currentDistanceFromBottom()
      publishBottomState(lastDistanceFromBottom <= Self.atBottomThreshold)
    }
    sendTransitions.advance()
    updateInitialPresentationReadiness()
    resolveBottomJumpIfPossible()
  }

  var effectiveRowWidth: CGFloat {
    let availableWidth = max(1, bounds.width - Self.horizontalPadding * 2)
    return min(Self.maxRowWidth, availableWidth)
  }

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
}
