import CodevisorCore
import SwiftUI

struct McpSecretRows: View {
  @Binding var entries: [McpSecretEntry]
  let valuePrompt: String

  var body: some View {
    ForEach($entries) { $entry in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          TextField("Name", text: $entry.name)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
          Button {
            entries.removeAll { $0.id == entry.id }
          } label: {
            Image(systemName: "minus.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove \(entry.name.isEmpty ? "entry" : entry.name)")
        }
        SecureField(entry.existing ? "Saved — enter a new value to replace" : valuePrompt, text: $entry.value)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
      }
    }
    Button {
      entries.append(McpSecretEntry(name: "", value: "", existing: false))
    } label: {
      Label("Add", systemImage: "plus")
    }
  }
}
