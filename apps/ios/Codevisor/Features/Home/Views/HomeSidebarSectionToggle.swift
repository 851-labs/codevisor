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
        Image(systemName: "chevron.forward")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
  }
}
