import SwiftUI

struct HomeSidebarDisclosureChevron: View {
  enum Style {
    case system
    case conversation
  }

  let isExpanded: Bool
  var style = Style.system

  var body: some View {
    Image(systemName: "chevron.forward")
      .font(font)
      .foregroundStyle(color)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
  }

  private var font: Font {
    switch style {
    case .system: .system(size: 14, weight: .semibold)
    case .conversation: .footnote.weight(.semibold)
    }
  }

  private var color: HierarchicalShapeStyle {
    switch style {
    case .system: .primary
    case .conversation: .tertiary
    }
  }
}
