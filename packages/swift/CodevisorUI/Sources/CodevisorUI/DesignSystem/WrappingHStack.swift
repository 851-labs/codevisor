import SwiftUI

/// Lays its children out left to right at their natural size, starting a new
/// line when the next one wouldn't fit. A child wider than the whole line gets
/// the line's width (and truncates) instead of overflowing.
public struct WrappingHStack: Layout {
  public var spacing: CGFloat
  public var lineSpacing: CGFloat

  public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
    self.spacing = spacing
    self.lineSpacing = lineSpacing
  }

  public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let placements = arrange(maxWidth: proposal.width, subviews: subviews)
    let width = placements.map { $0.frame.maxX }.max() ?? 0
    let height = placements.map { $0.frame.maxY }.max() ?? 0
    return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
  }

  public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for placement in arrange(maxWidth: bounds.width, subviews: subviews) {
      subviews[placement.index].place(
        at: CGPoint(x: bounds.minX + placement.frame.minX, y: bounds.minY + placement.frame.minY),
        proposal: ProposedViewSize(placement.frame.size))
    }
  }

  private struct Placement {
    let index: Int
    let frame: CGRect
  }

  private func arrange(maxWidth: CGFloat?, subviews: Subviews) -> [Placement] {
    let limit = maxWidth ?? .infinity
    var placements: [Placement] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    for index in subviews.indices {
      var size = subviews[index].sizeThatFits(.unspecified)
      if size.width > limit {
        size = subviews[index].sizeThatFits(ProposedViewSize(width: limit, height: nil))
        size.width = min(size.width, limit)
      }
      if x > 0, x + size.width > limit {
        x = 0
        y += lineHeight + lineSpacing
        lineHeight = 0
      }
      placements.append(Placement(index: index, frame: CGRect(origin: CGPoint(x: x, y: y), size: size)))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
    }
    return placements
  }
}
