import SwiftUI

struct ModelPickerChipLabel: View {
  let group: ModelMenuGroup?
  let title: String
  let hasSelection: Bool

  var body: some View {
    HStack(spacing: 5) {
      if let group, hasSelection {
        HarnessIcon(
          harnessId: group.id,
          fallbackSymbolName: group.symbolName,
          size: 13,
          weight: .medium
        )
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
      }

      Text(title)
        .foregroundStyle(group != nil && hasSelection ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .contentShape(Rectangle())
    .firstLaunchLandingTarget(.modelChip)
  }
}
