import SwiftUI

/// Provider selection stays searchable instead of growing an oversized menu.
public struct HarnessProviderPicker: View {
  public struct Provider: Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
  }

  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  private let providers: [Provider]
  @Binding private var selection: String

  public init(providers: [Provider], selection: Binding<String>) {
    self.providers = providers
    _selection = selection
  }

  public var body: some View {
    List {
      ForEach(providers.filter { search.isEmpty || $0.name.localizedStandardContains(search) }) { provider in
        Button {
          selection = provider.id
          dismiss()
        } label: {
          HStack {
            Text(provider.name).foregroundStyle(.primary)
            Spacer()
            if provider.id == selection { Image(systemName: "checkmark") }
          }
        }
      }
    }
    .searchable(text: $search, prompt: "Search providers")
    .navigationTitle("Providers")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}
