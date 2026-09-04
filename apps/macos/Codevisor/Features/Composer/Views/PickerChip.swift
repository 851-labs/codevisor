import SwiftUI

/// The label for composer accessory dropdowns: icon, text, and a chevron with
/// one shared styling so the pickers in the row read identically.
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
