import SwiftUI

struct HomeSidebarSectionToggle: View {
  let title: String
  @Binding var isExpanded: Bool

  var body: some View {
    Button {
      isExpanded.toggle()
    } label: {
      HStack {
        Text(title)
        Spacer(minLength: 0)
        HomeSidebarDisclosureChevron(isExpanded: isExpanded)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
