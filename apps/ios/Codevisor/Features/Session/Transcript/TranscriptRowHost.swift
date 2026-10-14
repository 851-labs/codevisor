import CodevisorUI
import SwiftUI
import TranscriptKit
import UIKit

@MainActor
final class TranscriptRowHost: UIView {
  private let contentController = TranscriptContentHostingController(
    rootView: AnyView(EmptyView()),
  )
  private var contentHost: UIView {
    contentController.view
  }

  private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(
    equalToConstant: 1,
  )
  private let verticalClipMask = CALayer()
  private static let horizontalOverflow: CGFloat = 4_096

  private(set) var representedRow: TranscriptVirtualRow?
  private(set) var isPresentationReady = false
  private(set) var isAttachmentGeometryReady = true
  var onMeasuredHeight: ((TranscriptRowMeasurement) -> Void)?

  init(parent: UIViewController) {
    super.init(frame: .zero)
    backgroundColor = .clear
    clipsToBounds = false
    verticalClipMask.backgroundColor = UIColor.black.cgColor
    layer.mask = verticalClipMask
    updateVerticalClipMask()

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
    updateVerticalClipMask()
    if syncContentWidth() {
      contentController.invalidateContentSize(forceReport: true)
    }
    super.layoutSubviews()
  }

  override var bounds: CGRect {
    didSet { updateVerticalClipMask() }
  }

  override var frame: CGRect {
    didSet { updateVerticalClipMask() }
  }

  private func updateVerticalClipMask() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    verticalClipMask.frame = bounds.insetBy(dx: -Self.horizontalOverflow, dy: 0)
    CATransaction.commit()
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: -Self.horizontalOverflow, dy: 0).contains(point)
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha >= 0.01, isUserInteractionEnabled,
      self.point(inside: point, with: event)
    else { return nil }
    if bounds.contains(point) { return super.hitTest(point, with: event) }
    return hitTestOverflow(in: contentHost, at: point, event: event)
  }

  private func hitTestOverflow(in view: UIView, at point: CGPoint, event: UIEvent?) -> UIView? {
    guard !view.isHidden, view.alpha >= 0.01, view.isUserInteractionEnabled else { return nil }
    let local = convert(point, to: view)
    if let hit = view.hitTest(local, with: event) { return hit }
    guard !view.clipsToBounds else { return nil }
    for child in view.subviews.reversed() {
      if let hit = hitTestOverflow(in: child, at: point, event: event) { return hit }
    }
    return nil
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
    let needsRoot =
      force
      || representedRow?.content != row.content
      || representedRow?.measurementRevision != row.measurementRevision
    representedRow = row
    guard needsRoot else { return }
    isPresentationReady = false
    isAttachmentGeometryReady = true
    if representsDifferentRow {
      TranscriptSendLayerAnimations.removeAll(from: layer)
    }
    contentController.installRootView(rootView)
  }

  func prepareForMountedRow() {
    TranscriptSendLayerAnimations.removeAll(from: layer)
  }

  func requestContentMeasurement(forceReport: Bool = true) {
    contentController.invalidateContentSize(forceReport: forceReport)
  }

  func prepareForImmediatePresentation() {
    setNeedsLayout()
    layoutIfNeeded()
    contentHost.setNeedsLayout()
    contentHost.layoutIfNeeded()
  }

  func resetReportedContentHeight() {
    isPresentationReady = false
    contentController.resetReportedHeight()
  }

  @discardableResult
  func setAttachmentGeometryReady(_ ready: Bool) -> Bool {
    guard isAttachmentGeometryReady != ready else { return false }
    isAttachmentGeometryReady = ready
    isPresentationReady = false
    if ready {
      contentController.invalidateContentSize(forceReport: true)
    }
    return true
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

    isPresentationReady = true
    onMeasuredHeight?(
      .init(
        key: row.layoutKey,
        revision: row.measurementRevision,
        rowWidthHalfPoints: Int((contentWidthConstraint.constant * 2).rounded()),
        height: height,
      ))
  }
}

extension TranscriptRowHost: TranscriptPresentableRowHost {}
