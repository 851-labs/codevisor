import AppKit
import CodevisorCore
import QuartzCore
import StreamMarkdown
import SwiftUI
import CodevisorUI
import TranscriptKit

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
  let surfaceController = TranscriptSurfaceController()
  let paginationLoadingIndicator = NSProgressIndicator()
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
  var activeRowsVersion: TranscriptRowSetRevision?

  var mountedHosts: [String: TranscriptMountedRowHost] = [:]
  let textSelection = TranscriptSelectionState()
  let find = TranscriptFindState()
  let hostPool = TranscriptHostPool()
  var disclosureCollapsePresentations: [UUID: DisclosureCollapsePresentation] = [:]
  var disclosureExitTasks: [UUID: Task<Void, Never>] = [:]
  var pendingDisclosureCollapseOrigins: [String: CGFloat]?
  var pendingDisclosureContainerOrigins: [(view: NSView, viewportY: CGFloat)] = []
  let markdownHostCache = TranscriptMarkdownHostCache()
  let virtualWindowPolicy = TranscriptVirtualWindowPolicy()
  var windowPlanner: TranscriptWindowPlanner {
    TranscriptWindowPlanner(
      policy: virtualWindowPolicy,
      initialRunwayViewportCount: Self.initialRunwayViewportCount
    )
  }
  var lastObservedViewportTop: CGFloat?
  var runwayMotion = TranscriptRunwayMotion()
  var remainingMountsThisFrame = 2
  var remainingRunwayPreparationsThisFrame = 1
  var rowContent: ((TranscriptVirtualRow) -> AnyView)?
  var markdownImageLoader: MarkdownImageLoader = .remote
  var openMarkdownLink: (@MainActor (URL) -> Bool)?
  var markdownImageActions: MarkdownImageActions?
  lazy var markdownLinkAction = MarkdownLinkAction(
    { [weak self] url in self?.openMarkdownLink?(url) ?? false },
    images: MarkdownImageActions(
      open: { [weak self] url in self?.markdownImageActions?.open(url) },
      openInNewTab: { [weak self] url in self?.markdownImageActions?.openInNewTab?(url) },
      copy: { [weak self] url in self?.markdownImageActions?.copy?(url) }))
  var markdownRowStyle = TranscriptMarkdownRowStyle(markdown: .default)
  var pendingMeasuredHeights: [String: CGFloat] = [:]
  var measurementCommitTask: Task<Void, Never>?
  weak var sessionController: SessionController?
  var presentationFrameDriverToken: TranscriptFrameDriverToken?
  var presentationDisplayLink: CADisplayLink?
  var isUpdatingMountedRows = false
  var deferredMountedRowsUpdateScheduled = false
  var deferredMountedRowsUpdateRequested = false
  var deferredMountedRowsRangeOverride: Range<Int>?
  var isAwaitingWarmProjection = false
  var disclosureViewportAnchor: TranscriptDisclosureViewportAnchor?
  var disclosureAnchorReleaseTask: Task<Void, Never>?

  var pendingInitialState: SessionScrollState?
  var hasOlderHistory = false
  var paginationHeaderLayout = TranscriptPaginationHeaderLayout()
  var isLoadingInitialHistory = false
  var isPreparingInitialProjection = true
  var isActiveProjectionPending = false
  var deferredActivePlaceholderKey: String?
  var isAwaitingFirstActiveProjection = false
  var scrollCommand = TranscriptScrollCommand()
  var hasReceivedScrollCommandForAttachment = false
  let sendTransitions = TranscriptSendTransitions<VirtualizedTranscriptScrollView>()
  var isSendTransitionCleanupScheduled = false
  var reduceMotion = false
  var positionApplicationDepth = 0
  var isApplyingPosition: Bool { positionApplicationDepth > 0 }
  var isHandlingUserInput = false
  var isLiveScrolling = false
  var userInputDeadline: TimeInterval = 0
  var lastDistanceFromBottom: CGFloat = 0
  var lastBottomState: Bool?
  var lastViewportSize: CGSize = .zero
  var lastViewportDistanceFromBottom: CGFloat = 0
  var historyPrefetchPolicy = TranscriptHistoryPrefetchPolicy()
  var isDetaching = false
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
  var mountWorkTime: () -> CFTimeInterval = CACurrentMediaTime
  var initialMountWorkStartedAt: CFTimeInterval?
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
  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    sendTransitions.adapter = self
    streamingTextFrameClock.setFrameRequester { [weak self] in
      self?.requestDisplayFrame()
    }
    drawsBackground = false
    backgroundColor = .clear
    borderType = .noBorder
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
    transcriptDocumentView.alphaValue = 0
    transcriptDocumentView.setAccessibilityHidden(true)
    verticalScroller?.isEnabled = false

    boundsObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification,
      object: contentView,
      queue: .main
    ) { [weak self] _ in
      Self.onMain { [weak self] in self?.viewportDidScroll() }
    }
    liveScrollObservers = [
      NotificationCenter.default.addObserver(
        forName: NSScrollView.willStartLiveScrollNotification,
        object: self,
        queue: .main
      ) { [weak self] _ in
        Self.onMain { [weak self] in
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
        Self.onMain { [weak self] in
          self?.mountedRowsUpdateRequested = false
          self?.updateMountedRows()
          self?.emitViewportSnapshot()
          self?.isHandlingUserInput = false
          self?.isLiveScrolling = false
          self?.markRecentUserInput()
          self?.requestMountedRowsUpdate()
        }
      },
    ]
    applicationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didResignActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Self.onMain { [weak self] in self?.sendTransitions.interrupt() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  nonisolated private static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
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
    for task in disclosureExitTasks.values { task.cancel() }
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
    if newWindow == nil, window != nil {
      republishLastStableScrollState()
      sendTransitions.interrupt()
      isDetaching = true
      uninstallPresentationFrameDriver()
      uninstallSelectionMouseMonitor()
    } else if newWindow != nil {
      isDetaching = false
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window != nil {
      installPresentationFrameDriver()
      installSelectionMouseMonitor()
    }
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned, textSelection.selection != nil {
      clearTranscriptSelection()
    }
    return resigned
  }

  override func mouseDown(with event: NSEvent) {
    if textSelection.selection != nil {
      clearTranscriptSelection()
    }
    super.mouseDown(with: event)
  }

  override func layout() {
    let previousSize = lastViewportSize
    let previousDistance = lastViewportDistanceFromBottom
    super.layout()
    if hasPendingViewportResize {
      applyPositionTransaction {
        layoutViewport(previousSize: previousSize, previousDistance: previousDistance)
      }
    } else {
      layoutViewport(previousSize: previousSize, previousDistance: previousDistance)
    }
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
    if event.keyCode == 53, textSelection.selection != nil {
      clearTranscriptSelection()
      return
    }
    if handleKeyboardScroll(with: event) { return }
    super.keyDown(with: event)
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

final class TranscriptDisclosureCollapseContainer: NSView {
  override var isFlipped: Bool { true }

  override func hitTest(_: NSPoint) -> NSView? { nil }
}
