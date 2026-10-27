import CodevisorCore
import SwiftUI

struct SandboxProviderSelect: View {
  let model: SandboxSettingsModel
  let selection: String?
  let onSelect: (ServerSandboxProvider) -> Void
  let onAdd: () -> Void
  let onManage: () -> Void

  var body: some View {
    SandboxSelect(
      label: "Provider",
      placeholder: "Select a provider",
      options: model.providers.map { provider in
        .init(
          id: provider.id, title: model.title(of: provider), icon: CodevisorSymbol.sandboxVendor(provider.vendor)
        )
      },
      selection: selection,
      onSelect: { id in model.provider(id).map(onSelect) }
    ) {
      if model.providers.isEmpty {
        Button("Add Provider…", systemImage: "plus", action: onAdd)
      } else {
        Divider()
        Button("Manage Providers…", systemImage: "gearshape", action: onManage)
      }
    }
  }
}
