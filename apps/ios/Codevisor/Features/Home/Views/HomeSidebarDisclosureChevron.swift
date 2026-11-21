import SwiftUI

struct HomeSidebarDisclosureChevron: View {
  let isExpanded: Bool

  var body: some View {
    Image(systemName: "chevron.forward")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .rotationEffect(.degrees(isExpanded ? 90 : 0))
  }
}
