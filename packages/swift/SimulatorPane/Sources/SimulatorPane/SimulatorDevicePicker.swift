#if canImport(AppKit)
  import Autocomplete
  import CodevisorClient
  import SwiftUI

  struct SimulatorDevicePicker: View {
    let model: SimulatorPaneModel
    let device: ServerSimulatorDevice

    @Autocomplete.ContentBuilder
    static func entries(model: SimulatorPaneModel) -> [Autocomplete.Entry] {
      Autocomplete.Picker(
        "Simulators",
        selection: Binding(get: { model.udid ?? "" }, set: { model.choose($0) }),
        options: SimulatorFamilies.sorted(model.list?.devices ?? [])
      ) { device in
        Autocomplete.Choice(device.name, value: device.udid) {
          HStack(spacing: 6) {
            Text(device.name).lineLimit(1)
            Text(device.isBooted ? "\(device.runtime.name) · Running" : device.runtime.name)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .searchTerms([device.runtime.name, device.deviceType.name])
      }
      .labelsHidden()
      Autocomplete.Footer(id: "actions") {
        Autocomplete.Action("Manage Simulators…", systemImage: "gearshape.fill") { model.managingSimulators = true }
          .help("Add, Rename and Delete Simulators")
      }
    }

    var body: some View {
      Autocomplete.Menu {
        Self.entries(model: model)
      } label: {
        HStack(spacing: 4) {
          Text(device.name)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
            .truncationMode(.middle)
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: 280)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
      }
      .fixedSize()
      .autocompleteSearchLabel("Search simulators")
      .autocompleteEmptyMessage("No matching simulators", noItems: "No simulators")
      .accessibilityLabel("Simulator, \(device.name), \(device.runtime.name)")
      .help("Choose a Simulator")
    }
  }
#endif
