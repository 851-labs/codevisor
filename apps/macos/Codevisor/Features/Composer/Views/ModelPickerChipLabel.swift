import SwiftUI

struct ModelPickerChipLabel: View {
  let group: ModelMenuGroup?
  let modelName: String?
  /// A pick is on its way to the harness; the name is already the chosen
  /// one, the spinner says it has not been confirmed yet.
  var isLoading = false

  var body: some View {
    HStack(spacing: 5) {
      if let modelName {
        if let group {
          HarnessIcon(
            harnessId: group.id,
            fallbackSymbolName: group.symbolName,
            size: 14
          )
          .foregroundStyle(.secondary)
          .frame(width: 16, height: 16)
          .accessibilityHidden(true)
        }

        Text(modelName)
          .foregroundStyle(.primary)
          .lineLimit(1)
          .truncationMode(.tail)
        if isLoading {
          ProgressView()
            .controlSize(.mini)
            .accessibilityHidden(true)
        }
      } else {
        Text("Select a harness")
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .contentShape(Rectangle())
  }
}
