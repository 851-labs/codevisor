import SwiftUI

struct ModelPickerChipLabel: View {
  let group: ModelMenuGroup?
  /// The selected model's name, or "Select a model" (see
  /// `ModelPickerPresentation`).
  let title: String
  let hasSelection: Bool

  var body: some View {
    HStack(spacing: 5) {
      if let group {
        if hasSelection {
          HarnessIcon(
            harnessId: group.id,
            fallbackSymbolName: group.symbolName,
            size: 14
          )
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
        }

        Text(title)
          .foregroundStyle(hasSelection ? .primary : .secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      } else {
        // No harness offers models (for example, only sign-in rows).
        Text("Select a harness")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .contentShape(Rectangle())
  }
}
