import AppKit
import CodevisorUI
import QuartzCore
import SwiftUI
import TranscriptKit

@MainActor
final class TranscriptRowHost: TranscriptMountedRowHost {
  private let contentController = TranscriptContentHostingController(rootView: AnyView(EmptyView()))
  private var contentHost: NSView { contentController.view }
  private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(equalToConstant: 1)
  private lazy var contentHeightConstraint = contentHost.heightAnchor.constraint(equalToConstant: 1)
  private var presentationReady = false
  private var attachmentGeometryReady = true
  private(set) var hasAttemptedPresentation = false
  private var hasStableContentGeometry = false
  private var canSkipContentLayout = false
  private var needsStableConstraintPass = false

  override var isPresentationReady: Bool { presentationReady }
  override var isAttachmentGeometryReady: Bool { attachmentGeometryReady }

  override var needsRunwayPreparation: Bool {
    !presentationReady
      && attachmentGeometryReady
      && (!hasAttemptedPresentation || needsStableConstraintPass)
  }

  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    installVerticalClipMask()
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
    contentController.onLayoutCompleted = { [weak self] in
      guard let self, self.hasStableContentGeometry else { return }
      if abs(self.contentHost.bounds.height - self.contentHeightConstraint.constant) > 0.5 {
        self.needsLayout = true
        self.contentHost.needsLayout = true
        return
      }
      self.needsStableConstraintPass = false
      let becameReady = !self.presentationReady
      self.presentationReady = true
      self.canSkipContentLayout = true
      if becameReady { self.onPresentationReady?() }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layout() {
    let width = max(1, bounds.width)
    if canSkipContentLayout,
      abs(contentWidthConstraint.constant - width) <= 0.5
    {
      contentHost.needsLayout = false
      return
    }
    if syncContentWidth() {
      canSkipContentLayout = false
      hasStableContentGeometry = false
      needsStableConstraintPass = false
      contentController.invalidateContentSize(forceReport: true)
    }
    super.layout()
  }

  @discardableResult
  override func syncContentWidth() -> Bool {
    let width = max(1, bounds.width)
    guard abs(contentWidthConstraint.constant - width) > 0.5 else { return false }
    contentWidthConstraint.constant = width
    return true
  }

  var rootView: AnyView {
    get { contentController.rootView }
    set { installRootView(newValue, knownHeight: nil) }
  }

  func installRootView(_ rootView: AnyView, knownHeight: CGFloat?) {
    presentationReady = false
    hasAttemptedPresentation = false
    hasStableContentGeometry = knownHeight != nil
    canSkipContentLayout = false
    needsStableConstraintPass = false
    if let knownHeight {
      contentHeightConstraint.constant = knownHeight
      contentController.useKnownContentHeight(knownHeight)
    } else {
      contentController.resetReportedHeight()
    }
    contentController.installRootView(rootView)
    if knownHeight == nil {
      contentController.invalidateContentSize(forceReport: true)
    }
  }

  override func prepareForMountedRow() {
    if let layer { TranscriptSendLayerAnimations.removeAll(from: layer) }
    presentationReady = false
    attachmentGeometryReady = true
    hasAttemptedPresentation = false
    hasStableContentGeometry = false
    canSkipContentLayout = false
    needsStableConstraintPass = false
    contentController.resetReportedHeight()
  }

  override func requestContentMeasurement(forceReport: Bool = true) {
    hasStableContentGeometry = false
    canSkipContentLayout = false
    needsStableConstraintPass = false
    hasAttemptedPresentation = false
    contentController.invalidateContentSize(forceReport: forceReport)
  }

  override func prepareForImmediatePresentation() {
    hasAttemptedPresentation = true
    canSkipContentLayout = false
    needsLayout = true
    contentHost.needsLayout = true
    layoutSubtreeIfNeeded()
  }

  @discardableResult
  override func setAttachmentGeometryReady(_ ready: Bool) -> Bool {
    guard attachmentGeometryReady != ready else { return false }
    attachmentGeometryReady = ready
    presentationReady = false
    hasStableContentGeometry = false
    canSkipContentLayout = false
    needsStableConstraintPass = false
    if ready {
      hasAttemptedPresentation = false
      contentController.invalidateContentSize(forceReport: true)
    }
    return true
  }

  private func contentHeightDidChange(_ height: CGFloat) {
    if abs(contentHeightConstraint.constant - height) > 0.5 {
      contentHeightConstraint.constant = height
    }
    hasStableContentGeometry = true
    presentationReady = false
    canSkipContentLayout = false
    needsStableConstraintPass = true
    needsLayout = true
    contentHost.needsLayout = true
    onHeightChange?(height)
  }
}
