import CodevisorCore
import SwiftUI

public struct McpSecretRows: View {
  private struct FieldKey: Hashable {
    let entry: UUID
    let isValue: Bool
  }

  @Binding var entries: [McpSecretEntry]
  let valuePrompt: String
  var onCommit: () -> Void = {}
  @FocusState private var focused: FieldKey?

  public init(entries: Binding<[McpSecretEntry]>, valuePrompt: String, onCommit: @escaping () -> Void = {}) {
    _entries = entries
    self.valuePrompt = valuePrompt
    self.onCommit = onCommit
  }

  public var body: some View {
    ForEach($entries) { $entry in
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          TextField("Name", text: $entry.name)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
              .textInputAutocapitalization(.never)
            #endif
            .focused($focused, equals: FieldKey(entry: entry.id, isValue: false))
            .onSubmit(onCommit)
          Button {
            entries.removeAll { $0.id == entry.id }
            onCommit()
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
          .focused($focused, equals: FieldKey(entry: entry.id, isValue: true))
          .onSubmit(onCommit)
      }
    }
    .onChange(of: focused) { previous, current in
      if let previous, previous.entry != current?.entry { onCommit() }
    }
    Button {
      entries.append(McpSecretEntry(name: "", value: "", existing: false))
    } label: {
      Label("Add", systemImage: "plus")
    }
  }
}
