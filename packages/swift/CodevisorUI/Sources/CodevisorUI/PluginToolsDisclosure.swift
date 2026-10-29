import SwiftUI

struct PluginToolsDisclosure<Rows: View>: View {
  let count: Int
  var isLoading = false
  @ViewBuilder let rows: () -> Rows
  @State private var isExpanded = false

  var body: some View {
    Section {
      SettingsDisclosureRows(isExpanded: $isExpanded) {
        LabeledContent("Tools") {
          if isLoading {
            ProgressView().controlSize(.small)
          } else {
            Text(count, format: .number)
          }
        }
        .foregroundStyle(.primary)
      } content: {
        if count == 0 && !isLoading {
          Text("No tools available").foregroundStyle(.secondary)
        } else {
          rows()
        }
      }
    }
  }
}
