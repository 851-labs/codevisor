import SwiftUI

struct HomeSidebarSectionToggle: View {
  let title: String
  @Binding var isExpanded: Bool
  var chevron = HomeSidebarDisclosureChevron.Style.system

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack {
        Text(title)
        Spacer(minLength: 0)
        HomeSidebarDisclosureChevron(isExpanded: isExpanded, style: chevron)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
