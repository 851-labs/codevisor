import CoreGraphics
import Foundation

enum ComputerUseNativePreviewMetrics {
  static let maximumDimension: CGFloat = 960
  static let maximumViewingDimension: CGFloat = 1920
  static let fallbackSize = CGSize(width: 640, height: 360)
  static let idleFramesPerSecond: Int32 = 5
  static let viewingFramesPerSecond: Int32 = 15
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
