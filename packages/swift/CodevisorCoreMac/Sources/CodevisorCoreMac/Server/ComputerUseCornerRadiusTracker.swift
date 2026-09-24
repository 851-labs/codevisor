import CoreGraphics
import CoreVideo
import Foundation

/// How far a continuous (squircle) rounded rect's edge sits from its corner
/// along the 45° diagonal, per point of corner radius.
let computerUseContinuousCornerDiagonalInset: CGFloat = 0.2916

/// Where the streamed window sits in its frame, measured from the frame.
///
/// The preview stream captures one window with its shadow removed. The
/// capture buffer's even-pixel size rarely matches the window's aspect
/// exactly, so the window arrives fitted inside with a pixel or two of
/// transparent padding, and its rounded corners are transparent too.
public struct ComputerUseWindowContent: Equatable, Sendable {
  /// The window's opaque bounds in unit coordinates of the frame, y-down.
  public let rect: CGRect
  /// The window's corner radius as a fraction of the window's width.
  public let cornerRadiusFraction: CGFloat

  public init(rect: CGRect, cornerRadiusFraction: CGFloat) {
    self.rect = rect
    self.cornerRadiusFraction = cornerRadiusFraction
  }

  /// Close enough that re-laying out the card would be noise.
  func isClose(to other: ComputerUseWindowContent) -> Bool {
    abs(rect.minX - other.rect.minX) < 0.0005 && abs(rect.minY - other.rect.minY) < 0.0005
      && abs(rect.width - other.rect.width) < 0.0005 && abs(rect.height - other.rect.height) < 0.0005
      && abs(cornerRadiusFraction - other.cornerRadiusFraction) < 0.0005
  }
}

/// Measures the window in a frame whose pixel alpha is `alpha(x, y)`, y-down.
///
/// Transparency summed along a line gives its transparent run with sub-pixel
/// accuracy: across each edge at mid-height or mid-width for the padding,
/// and along each top corner's diagonal for the corner. Returns nil when the
/// frame can't tell: no alpha (the centre isn't opaque), or padding or a
/// corner too deep to be a window's, as when the frame is letterboxed.
func computerUseWindowContent(
  width: Int,
  height: Int,
  alpha: (_ x: Int, _ y: Int) -> UInt8
) -> ComputerUseWindowContent? {
  guard width >= 16, height >= 16, alpha(width / 2, height / 2) == 255 else { return nil }
  let limit = min(width, height) / 8
  func transparentRun(_ point: (Int) -> (x: Int, y: Int)) -> CGFloat? {
    var run: CGFloat = 0
    for step in 0..<limit {
      let (x, y) = point(step)
      let value = alpha(x, y)
      if value == 255 { return run }
      run += 1 - CGFloat(value) / 255
    }
    return nil
  }
  guard
    let left = transparentRun({ ($0, height / 2) }),
    let right = transparentRun({ (width - 1 - $0, height / 2) }),
    let top = transparentRun({ (width / 2, $0) }),
    let bottom = transparentRun({ (width / 2, height - 1 - $0) })
  else { return nil }
  // Walk each corner's diagonal from the window's own corner, not the frame's.
  let leftStart = Int(left.rounded()), rightStart = Int(right.rounded()), topStart = Int(top.rounded())
  guard
    let leading = transparentRun({ (leftStart + $0, topStart + $0) }),
    let trailing = transparentRun({ (width - 1 - rightStart - $0, topStart + $0) })
  else { return nil }
  let contentWidth = CGFloat(width) - left - right
  let contentHeight = CGFloat(height) - top - bottom
  guard contentWidth > 0, contentHeight > 0 else { return nil }
  let radius = (leading + trailing) / 2 / computerUseContinuousCornerDiagonalInset
  return ComputerUseWindowContent(
    rect: CGRect(
      x: left / CGFloat(width),
      y: top / CGFloat(height),
      width: contentWidth / CGFloat(width),
      height: contentHeight / CGFloat(height)
    ),
    cornerRadiusFraction: radius / contentWidth
  )
}

/// Measures a BGRA frame. Nil for other pixel formats.
func computerUseWindowContent(pixelBuffer: CVPixelBuffer) -> ComputerUseWindowContent? {
  guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
  guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
  defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
  guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
  let bytes = base.assumingMemoryBound(to: UInt8.self)
  let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
  return computerUseWindowContent(
    width: CVPixelBufferGetWidth(pixelBuffer),
    height: CVPixelBufferGetHeight(pixelBuffer)
  ) { x, y in
    bytes[y * bytesPerRow + x * 4 + 3]
  }
}

/// Decides when to re-measure the window and when a new measurement is
/// worth reporting. Not thread-safe; the owner serialises access.
struct ComputerUseCornerRadiusTracker {
  /// Frames between re-measurements at an unchanged size, so a switch to a
  /// same-sized window is still picked up.
  static let remeasureInterval = 30

  private(set) var content: ComputerUseWindowContent?
  private var frameSize: CGSize?
  private var framesSinceMeasurement = 0

  /// Whether the next frame of `size` should be measured.
  mutating func shouldMeasure(size: CGSize) -> Bool {
    framesSinceMeasurement += 1
    guard size == frameSize, framesSinceMeasurement < Self.remeasureInterval else {
      frameSize = size
      framesSinceMeasurement = 0
      return true
    }
    return false
  }

  /// Records a measurement. Returns it when it changed noticeably, nil
  /// otherwise. Failed measurements keep the last value.
  mutating func record(_ measured: ComputerUseWindowContent?) -> ComputerUseWindowContent? {
    guard let measured else { return nil }
    if let content, content.isClose(to: measured) { return nil }
    content = measured
    return measured
  }
}

extension ComputerUseLivePreviewLayout {
  /// Card corner radius when the window's own radius is unknown.
  public static let fallbackCornerRadius: CGFloat = 12

  /// The card's corner radius: the window's radius scaled by the card's
  /// zoom, so the card's corners line up with the window's. Falls back to a
  /// fixed radius, and never exceeds a quarter of the short side so a small
  /// card doesn't turn into a pill.
  public static func cardCornerRadius(radiusFraction: CGFloat?, cardSize: CGSize) -> CGFloat {
    let ceiling = max(0, min(cardSize.width, cardSize.height) / 4)
    guard let radiusFraction, radiusFraction.isFinite, radiusFraction >= 0 else {
      return min(fallbackCornerRadius, ceiling)
    }
    return min(radiusFraction * cardSize.width, ceiling)
  }

  /// Where to lay out the stream in a card of `cardSize` so the window
  /// covers the card edge to edge: the returned rect, in the card's
  /// coordinates, has the frame's aspect (so the renderer adds no
  /// letterbox of its own) and overhangs the card by the frame's
  /// transparent padding plus up to a pixel of rounding, which the card's
  /// clip trims. `content` is the window's unit rect in the frame; nil
  /// treats the whole frame as the window.
  public static func surfaceFrame(frameSize: CGSize?, content: CGRect?, cardSize: CGSize) -> CGRect {
    let fill = CGRect(origin: .zero, size: cardSize)
    guard let frameSize, frameSize.width > 0, frameSize.height > 0 else { return fill }
    var window = CGRect(x: 0, y: 0, width: 1, height: 1)
    if let content, content.width > 0.5, content.height > 0.5, content.minX >= 0, content.minY >= 0,
      content.maxX <= 1.0001, content.maxY <= 1.0001
    {
      window = content
    }
    let windowWidth = frameSize.width * window.width
    let windowHeight = frameSize.height * window.height
    let scale = max(cardSize.width / windowWidth, cardSize.height / windowHeight)
    guard scale.isFinite, scale > 0 else { return fill }
    let width = frameSize.width * scale
    let height = frameSize.height * scale
    // Centre the window on the card; any excess splits evenly.
    let excessX = windowWidth * scale - cardSize.width
    let excessY = windowHeight * scale - cardSize.height
    return CGRect(
      x: -window.minX * width - excessX / 2,
      y: -window.minY * height - excessY / 2,
      width: width,
      height: height
    )
  }
}
