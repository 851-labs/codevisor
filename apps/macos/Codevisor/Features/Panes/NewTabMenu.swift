import Autocomplete
import CodevisorCore
import CodevisorUI
import SwiftUI

/// The tab bar's `+`: a searchable popover of what a new tab can open (the
/// same picker the composer uses for models). Choosing opens it straight
/// into a new tab at the end of the bar, so there is no empty New Tab page
/// to pass through.
struct NewTabMenu: View {
  @Environment(AppEnvironment.self) private var environment
  @Binding var isPresented: Bool
  let machineId: String
  let open: (NewTabOption) -> Void

  @State private var pluginOptions: [NewTabOption] = []

  private var options: [NewTabOption] {
    let status = environment.machines.statusByMachineId[machineId]
    return NewTabOption.builtIns(
      supportsScreenSharing: status?.supportsScreenSharing == true,
      supportsSimulator: status?.supportsSimulator == true)
      + pluginOptions
  }

  var body: some View {
    let client = environment.machines.client(for: machineId)
    Autocomplete.Menu(isPresented: $isPresented) {
      for option in options {
        if case let .plugin(pluginId, paneType, iconPath) = option.kind {
          Autocomplete.Action(option.title, id: option.id, action: { open(option) }) {
            PluginIconView(
              pluginId: pluginId, paneType: paneType, iconPath: iconPath,
              client: client, cacheNamespace: machineId)
          } label: {
            Text(option.title)
          }
        } else {
          Autocomplete.Action(option.title, id: option.id, systemImage: option.systemImage) { open(option) }
        }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 12, weight: .medium))
        .frame(width: 26, height: 26)
        .contentShape(Rectangle())
    }
    .autocompleteSearchLabel("Search new tab options")
    .autocompleteEmptyMessage("No matching options")
    .buttonStyle(.borderless)
    .help("New Tab (⌘T)")
    .accessibilityLabel("New Tab")
    .task(id: environment.pluginStateRevision(for: machineId)) {
      pluginOptions = await NewTabOption.plugins(client: client)
    }
  }
}
