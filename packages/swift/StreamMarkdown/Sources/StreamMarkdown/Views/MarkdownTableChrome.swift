import CoreGraphics

struct MarkdownTableChrome {
  let geometry: MarkdownTableGeometry

  var headerFrame: CGRect {
    guard rowCount > 0 else { return .zero }
    return CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.rowOffsets[1])
  }

  func rules(intersecting rect: CGRect) -> [CGRect] {
    geometry.rows(intersecting: rect).filter { $0 < rowCount - 1 }.map(rule(below:))
  }

  func fillHeader(in context: CGContext, color: CGColor) {
    context.setFillColor(color)
    context.fill(headerFrame)
  }

  func fillRules(intersecting rect: CGRect, in context: CGContext, color: CGColor) {
    context.setFillColor(color)
    context.fill(rules(intersecting: rect))
  }

  private var rowCount: Int { geometry.rowOffsets.count - 1 }

  private func rule(below row: Int) -> CGRect {
    CGRect(
      x: 0, y: geometry.rowOffsets[row + 1] - MarkdownTableMetrics.ruleThickness,
      width: geometry.size.width, height: MarkdownTableMetrics.ruleThickness
    )
  }
}
