import AppKit
import QuartzCore
import TranscriptKit

/// Common lifecycle understood by the transcript virtualizer.
///
/// Interactive rows use ``TranscriptRowHost`` and SwiftUI. Settled Markdown
/// uses ``TranscriptMarkdownRowHost`` and never constructs a hosting
/// controller. Keeping the boundary here prevents renderer-specific work from
/// leaking back into scroll scheduling.
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

  // MARK: - Vertical-only clipping

  private static let horizontalClipSlack: CGFloat = 4096
  private var verticalClipMask: CALayer? { layer?.mask }

  /// The virtualizer owns row geometry: until a natural height is committed,
  /// hosted content must stay inside the ledger frame so an estimate never
  /// paints over its neighbour. That guarantee is about *height*. Clipping
  /// horizontally as well would stop a wide table's scroll viewport from
  /// bleeding past the text column (as it does on iOS), so the mask spans
  /// the row's height only.
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
