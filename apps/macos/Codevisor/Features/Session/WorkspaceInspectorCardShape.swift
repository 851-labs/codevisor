import SwiftUI

nonisolated enum WorkspaceInspectorCardShape {
  static let cornerRadius: CGFloat = 10
  static let rowPadding: CGFloat = 10
  static let card = RoundedRectangle(cornerRadius: cornerRadius)

  static func row<Item: Identifiable>(for item: Item, in items: [Item]) -> UnevenRoundedRectangle {
    row(isFirst: item.id == items.first?.id, isLast: item.id == items.last?.id)
  }

  private static func row(isFirst: Bool, isLast: Bool) -> UnevenRoundedRectangle {
    let top = isFirst ? cornerRadius : 0
    let bottom = isLast ? cornerRadius : 0
    return UnevenRoundedRectangle(
      topLeadingRadius: top,
      bottomLeadingRadius: bottom,
      bottomTrailingRadius: bottom,
      topTrailingRadius: top
    )
  }
}
