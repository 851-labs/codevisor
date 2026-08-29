import SwiftUI

struct ModelPickerChipLabel: View {
    let group: ModelMenuGroup?
    let modelName: String?

    var body: some View {
        HStack(spacing: 5) {
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

            if let modelName {
                Text(modelName)
                    .foregroundStyle(.primary)
            } else {
                Text("Select a harness")
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
