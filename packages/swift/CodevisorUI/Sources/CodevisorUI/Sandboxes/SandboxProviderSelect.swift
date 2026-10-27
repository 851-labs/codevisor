import CodevisorCore
import SwiftUI

struct SandboxProviderSelect: View {
  let model: SandboxSettingsModel
  let selection: String?
  let onSelect: (ServerSandboxProvider) -> Void
  let onAdd: () -> Void
  let onEdit: (ServerSandboxProvider) -> Void

  var body: some View {
    SandboxSelect(
      label: "Provider",
      placeholder: "Select a provider",
      options: model.providers.map { provider in
        .init(
          id: provider.id, title: model.title(of: provider), systemImage: SandboxVendorSymbol.name(for: provider.vendor)
        )
      },
      selection: selection,
      onSelect: { id in model.provider(id).map(onSelect) }
    ) {
      Divider()
      Button("Add Provider…", systemImage: "plus", action: onAdd)
      if !model.providers.isEmpty {
        Menu("Edit Provider", systemImage: "pencil") {
          ForEach(model.providers) { provider in
            Button(model.title(of: provider)) { onEdit(provider) }
          }
        }
      }
    }
  }
}
