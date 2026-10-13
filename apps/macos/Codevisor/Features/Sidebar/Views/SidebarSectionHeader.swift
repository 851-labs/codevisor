import SwiftUI

/// A compact heading above a run of sidebar rows, with a trailing control.
struct SidebarSectionHeader<Accessory: View>: View {
  let title: String
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    HStack(spacing: 6) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)

      Spacer(minLength: 0)

      accessory()
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }
}
