import AppKit
import QuartzCore
import TranscriptKit

@MainActor
class TranscriptMountedRowHost: NSView {
  var onHeightChange: ((CGFloat) -> Void)?
  var onPresentationReady: (() -> Void)?

  var isPresentationReady: Bool { false }
  var isAttachmentGeometryReady: Bool { true }
  var needsRunwayPreparation: Bool { !isPresentationReady }

  func prepareForMountedRow() {}
  func syncContentWidth() -> Bool { false }
  func prepareForImmediatePresentation() {}
  func requestContentMeasurement(forceReport _: Bool = true) {}

  @discardableResult
  func setAttachmentGeometryReady(_: Bool) -> Bool { false }

  private static let horizontalClipSlack: CGFloat = 4096
  private var verticalClipMask: CALayer? { layer?.mask }

  func installVerticalClipMask() {
    wantsLayer = true
    layer?.masksToBounds = false
    let mask = CALayer()
    mask.backgroundColor = NSColor.black.cgColor
    layer?.mask = mask
    updateVerticalClipMask()
  }

  private func updateVerticalClipMask() {
    guard let mask = verticalClipMask else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    mask.frame = CGRect(
      x: -Self.horizontalClipSlack,
      y: 0,
      width: bounds.width + Self.horizontalClipSlack * 2,
      height: bounds.height
    )
    CATransaction.commit()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateVerticalClipMask()
  }
}

extension TranscriptMountedRowHost: TranscriptPresentableRowHost {}
