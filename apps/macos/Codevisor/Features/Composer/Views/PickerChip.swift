import SwiftUI

struct PickerChip<Icon: View>: View {
  let text: String
  @ViewBuilder let icon: Icon

  var body: some View {
    HStack(spacing: 5) {
      icon
        .foregroundStyle(.secondary)
      Text(text)
        .foregroundStyle(.primary)
    }
    .contentShape(Rectangle())
  }
}
