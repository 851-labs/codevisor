import CoreGraphics

enum PluginAppPipLayout {
  enum Corner: CaseIterable, Sendable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
  }

  static let inset: CGFloat = 12
  static let headerHeight: CGFloat = 32
  static let heightRange: ClosedRange<CGFloat> = 120...420

  static func size(contentHeight: CGFloat, container: CGSize, preferredWidth: CGFloat) -> CGSize {
    let width = max(160, min(preferredWidth, container.width - inset * 2))
    let maximum = max(heightRange.lowerBound, min(heightRange.upperBound, container.height * 0.6))
    let height = min(max(contentHeight, heightRange.lowerBound), maximum)
    return CGSize(width: width, height: height + headerHeight)
  }

  static func origin(corner: Corner, size: CGSize, container: CGSize) -> CGPoint {
    let leading = inset
    let trailing = max(inset, container.width - size.width - inset)
    let top = inset
    let bottom = max(inset, container.height - size.height - inset)
    switch corner {
    case .topLeading: return CGPoint(x: leading, y: top)
    case .topTrailing: return CGPoint(x: trailing, y: top)
    case .bottomLeading: return CGPoint(x: leading, y: bottom)
    case .bottomTrailing: return CGPoint(x: trailing, y: bottom)
    }
  }

  static func nearestCorner(to center: CGPoint, container: CGSize) -> Corner {
    let isLeading = center.x < container.width / 2
    let isTop = center.y < container.height / 2
    switch (isTop, isLeading) {
    case (true, true): return .topLeading
    case (true, false): return .topTrailing
    case (false, true): return .bottomLeading
    case (false, false): return .bottomTrailing
    }
  }
}
