import CoreGraphics
import CoreVideo
import Foundation

let computerUseContinuousCornerDiagonalInset: CGFloat = 0.2916

public struct ComputerUseWindowContent: Equatable, Sendable {
  public let rect: CGRect
  public let cornerRadiusFraction: CGFloat

  public init(rect: CGRect, cornerRadiusFraction: CGFloat) {
    self.rect = rect
    self.cornerRadiusFraction = cornerRadiusFraction
  }

  func isClose(to other: ComputerUseWindowContent) -> Bool {
    abs(rect.minX - other.rect.minX) < 0.0005 && abs(rect.minY - other.rect.minY) < 0.0005
      && abs(rect.width - other.rect.width) < 0.0005 && abs(rect.height - other.rect.height) < 0.0005
      && abs(cornerRadiusFraction - other.cornerRadiusFraction) < 0.0005
  }
}

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

struct ComputerUseCornerRadiusTracker {
  static let remeasureInterval = 30

  private(set) var content: ComputerUseWindowContent?
  private var frameSize: CGSize?
  private var framesSinceMeasurement = 0

  mutating func shouldMeasure(size: CGSize) -> Bool {
    framesSinceMeasurement += 1
    guard size == frameSize, framesSinceMeasurement < Self.remeasureInterval else {
      frameSize = size
      framesSinceMeasurement = 0
      return true
    }
    return false
  }

  mutating func record(_ measured: ComputerUseWindowContent?) -> ComputerUseWindowContent? {
    guard let measured else { return nil }
    if let content, content.isClose(to: measured) { return nil }
    content = measured
    return measured
  }
}
