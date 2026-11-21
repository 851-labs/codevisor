import UIKit

struct HomeSidebarCardEdges: Equatable {
  let top: Bool
  let bottom: Bool
}

enum HomeSidebarCardBackground {
  static let radius: CGFloat = 26

  static func configuration(edges: HomeSidebarCardEdges, isHighlighted: Bool) -> UIBackgroundConfiguration {
    var configuration = UIBackgroundConfiguration.clear()
    configuration.customView = cardView(edges: edges, isHighlighted: isHighlighted)
    return configuration
  }

  private static func cardView(edges: HomeSidebarCardEdges, isHighlighted: Bool) -> UIView {
    let view = UIView()
    view.backgroundColor = isHighlighted ? .systemGray4 : .secondarySystemGroupedBackground
    view.layer.cornerRadius = radius
    view.layer.cornerCurve = .continuous
    view.layer.maskedCorners = corners(edges)
    return view
  }

  private static func corners(_ edges: HomeSidebarCardEdges) -> CACornerMask {
    var corners: CACornerMask = []
    if edges.top { corners.formUnion([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
    if edges.bottom { corners.formUnion([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
    return corners
  }
}
