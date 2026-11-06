import CoreGraphics

public enum FloatingPaneGeometry {
  public static let margin = ComputerUseLivePreviewLayout.margin
  public static let minimumSize = CGSize(width: 280, height: 180)
  public static let defaultSize = CGSize(width: 420, height: 480)
  public static let cascadeStep: CGFloat = 28
  public static let snapDistance: CGFloat = 16

  public static func defaultFrame(index: Int, container: CGSize) -> CGRect {
    let cascade = CGFloat(index) * cascadeStep
    let origin = CGPoint(x: container.width - defaultSize.width - margin - cascade, y: margin + cascade)
    return clamped(CGRect(origin: origin, size: defaultSize), container: container)
  }

  public static func fits(in container: CGSize) -> Bool {
    container.width >= minimumSize.width + margin * 2 && container.height >= minimumSize.height + margin * 2
  }

  public static func clamped(_ frame: CGRect, container: CGSize) -> CGRect {
    let bounds = allowedBounds(container)
    let size = clampedSize(frame.size, bounds: bounds.size)
    let x = min(max(frame.minX, bounds.minX), bounds.maxX - size.width)
    let y = min(max(frame.minY, bounds.minY), bounds.maxY - size.height)
    return CGRect(x: x, y: y, width: size.width, height: size.height)
  }

  public static func moved(_ frame: CGRect, by translation: CGSize, container: CGSize) -> CGRect {
    clamped(frame.offsetBy(dx: translation.width, dy: translation.height), container: container)
  }

  public static func snapped(_ frame: CGRect, container: CGSize) -> CGRect {
    let bounds = allowedBounds(container)
    let x = snap(frame.minX...frame.maxX, within: bounds.minX...bounds.maxX)
    let y = snap(frame.minY...frame.maxY, within: bounds.minY...bounds.maxY)
    return CGRect(x: x, y: y, width: frame.width, height: frame.height)
  }

  public static func resized(
    _ frame: CGRect,
    handle: ComputerUseLivePreviewResizeHandle,
    translation: CGSize,
    container: CGSize
  ) -> CGRect {
    let bounds = allowedBounds(container)
    let horizontal = resizedSpan(
      frame.minX, frame.maxX, delta: translation.width, direction: handle.horizontal,
      limits: bounds.minX...bounds.maxX, minimum: minimumSize.width)
    let vertical = resizedSpan(
      frame.minY, frame.maxY, delta: translation.height, direction: handle.vertical,
      limits: bounds.minY...bounds.maxY, minimum: minimumSize.height)
    return CGRect(
      x: horizontal.lowerBound, y: vertical.lowerBound,
      width: horizontal.upperBound - horizontal.lowerBound, height: vertical.upperBound - vertical.lowerBound)
  }

  private static func allowedBounds(_ container: CGSize) -> CGRect {
    CGRect(x: margin, y: margin, width: container.width - margin * 2, height: container.height - margin * 2)
  }

  private static func clampedSize(_ size: CGSize, bounds: CGSize) -> CGSize {
    CGSize(
      width: min(max(size.width, minimumSize.width), max(minimumSize.width, bounds.width)),
      height: min(max(size.height, minimumSize.height), max(minimumSize.height, bounds.height))
    )
  }

  private static func snap(_ span: ClosedRange<CGFloat>, within edges: ClosedRange<CGFloat>) -> CGFloat {
    let length = span.upperBound - span.lowerBound
    if abs(span.lowerBound - edges.lowerBound) <= snapDistance { return edges.lowerBound }
    if abs(edges.upperBound - span.upperBound) <= snapDistance { return edges.upperBound - length }
    return span.lowerBound
  }

  private static func resizedSpan(
    _ low: CGFloat,
    _ high: CGFloat,
    delta: CGFloat,
    direction: CGFloat,
    limits: ClosedRange<CGFloat>,
    minimum: CGFloat
  ) -> ClosedRange<CGFloat> {
    if direction < 0 {
      let newLow = min(max(low + delta, limits.lowerBound), high - minimum)
      return newLow...high
    }
    if direction > 0 {
      let newHigh = max(min(high + delta, limits.upperBound), low + minimum)
      return low...newHigh
    }
    return low...high
  }
}
