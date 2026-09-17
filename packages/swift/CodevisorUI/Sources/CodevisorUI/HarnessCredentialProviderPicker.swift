import SwiftUI

struct HarnessCredentialProviderPicker: View {
  @Environment(\.dismiss) private var dismiss
  let providers: [String: String]
  @Binding var selection: String
  @State private var search = ""

  private var visibleIds: [String] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return providers.keys.filter {
      query.isEmpty || (providers[$0] ?? $0).localizedStandardContains(query) || $0.localizedStandardContains(query)
    }.sorted { (providers[$0] ?? $0).localizedStandardCompare(providers[$1] ?? $1) == .orderedAscending }
  }

  var body: some View {
    List {
      Section {
        ForEach(visibleIds, id: \.self) { id in
          row(id, name: providers[id] ?? id)
        }
      }
      Section {
        row("", name: "Other Provider…")
      }
    }
    .searchable(text: $search, prompt: "Search Providers")
    .navigationTitle("Provider")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  private func row(_ id: String, name: String) -> some View {
    Button {
      selection = id
      dismiss()
    } label: {
      HStack {
        Text(name)
        Spacer()
        if selection == id {
          Image(systemName: "checkmark").foregroundStyle(.tint)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selection == id ? .isSelected : [])
  }
}
