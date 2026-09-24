import CoreGraphics
import Foundation

enum ComputerUseNativePreviewMetrics {
  static let maximumDimension: CGFloat = 960
  /// Ceiling for a viewer that displays the preview larger than the default:
  /// sharp on Retina without capturing every window at full resolution.
  static let maximumViewingDimension: CGFloat = 1920
  static let fallbackSize = CGSize(width: 640, height: 360)
  /// Enough to keep the system's sharing preview populated.
  static let idleFramesPerSecond: Int32 = 5
  /// Watchable when a live preview viewer is attached.
  static let viewingFramesPerSecond: Int32 = 15
  /// SCK stops delivering once the client holds the whole pool. A viewer's
  /// renderer can pin three buffers at once (mailbox slot, last frame kept
  /// for redraws, the frame in flight on the GPU), so leave headroom.
  static let queueDepth = 5
}

struct ComputerUseNativePreviewSettings: Equatable, Sendable {
  let size: CGSize
  let framesPerSecond: Int32
}

func computerUseNativePreviewFramesPerSecond(viewerCount: Int) -> Int32 {
  viewerCount > 0
    ? ComputerUseNativePreviewMetrics.viewingFramesPerSecond
    : ComputerUseNativePreviewMetrics.idleFramesPerSecond
}

/// The longer side the preview is captured at: the default, raised to what
/// the largest viewer displays in pixels, within a ceiling.
func computerUseNativePreviewMaximumDimension(requestedDimension: CGFloat) -> CGFloat {
  guard requestedDimension.isFinite else { return ComputerUseNativePreviewMetrics.maximumDimension }
  return min(
    ComputerUseNativePreviewMetrics.maximumViewingDimension,
    max(ComputerUseNativePreviewMetrics.maximumDimension, requestedDimension.rounded(.up))
  )
}

func computerUseNativePreviewSettings(
  windowFrame: CGRect,
  pointPixelScale: CGFloat,
  viewerCount: Int,
  requestedDimension: CGFloat = 0
) -> ComputerUseNativePreviewSettings {
  ComputerUseNativePreviewSettings(
    size: computerUseNativePreviewSize(
      windowFrame: windowFrame,
      pointPixelScale: pointPixelScale,
      maximumDimension: computerUseNativePreviewMaximumDimension(requestedDimension: requestedDimension)
    ),
    framesPerSecond: computerUseNativePreviewFramesPerSecond(viewerCount: viewerCount)
  )
}

/// Produces an even-sized, aspect-preserving preview buffer. The model still
/// receives an independent full-resolution screenshot on demand; this stream
/// exists for macOS's native sharing UI and lifecycle.
func computerUseNativePreviewSize(
  windowFrame: CGRect,
  pointPixelScale: CGFloat,
  maximumDimension: CGFloat = ComputerUseNativePreviewMetrics.maximumDimension
) -> CGSize {
  guard windowFrame.width.isFinite,
    windowFrame.height.isFinite,
    windowFrame.width > 0,
    windowFrame.height > 0,
    pointPixelScale.isFinite,
    pointPixelScale > 0,
    maximumDimension.isFinite,
    maximumDimension >= 2
  else { return ComputerUseNativePreviewMetrics.fallbackSize }

  let nativeSize = CGSize(
    width: windowFrame.width * pointPixelScale,
    height: windowFrame.height * pointPixelScale
  )
  let reduction = min(1, maximumDimension / max(nativeSize.width, nativeSize.height))

  func evenDimension(_ value: CGFloat) -> CGFloat {
    CGFloat(max(2, Int((value * reduction).rounded(.down)) & ~1))
  }

  return CGSize(
    width: evenDimension(nativeSize.width),
    height: evenDimension(nativeSize.height)
  )
}
