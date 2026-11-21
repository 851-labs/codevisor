import SwiftUI

struct HomeSidebarCardEdges: Equatable {
  let top: Bool
  let bottom: Bool
}

struct HomeSidebarCardBackground: View {
  static let radius: CGFloat = 26

  let edges: HomeSidebarCardEdges

  var body: some View {
    UnevenRoundedRectangle(
      topLeadingRadius: edges.top ? Self.radius : 0, bottomLeadingRadius: edges.bottom ? Self.radius : 0,
      bottomTrailingRadius: edges.bottom ? Self.radius : 0, topTrailingRadius: edges.top ? Self.radius : 0,
      style: .continuous
    )
    .fill(Color(uiColor: .secondarySystemGroupedBackground))
  }
}

struct HomeSidebarCardRow: ViewModifier {
  let edges: HomeSidebarCardEdges?

  func body(content: Content) -> some View {
    if let edges {
      content.listRowBackground(HomeSidebarCardBackground(edges: edges))
    } else {
      content
    }
  }
}
