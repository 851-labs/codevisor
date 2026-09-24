import CodevisorCore
import SwiftUI

/// Header or environment entries, as plain SwiftUI rows.
///
/// The Mac has its own AppKit-backed editor for this; nothing in it needs
/// AppKit, so this version works on both and is what the shared form uses.
/// A value the server already holds arrives name-only — secrets never come
/// back — so its field stays empty and says so rather than pretending to
/// show something.
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
