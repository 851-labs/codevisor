#if canImport(AppKit)
  import Autocomplete
  import CodevisorClient
  import SwiftUI

  /// The Mac's device picker, where the window title would be: the device and its OS, opening a
  /// searchable list of the Mac's simulators by kind, with a footer to create another. The same
  /// autocomplete menu as the Review pane's branch picker.
  struct SimulatorDevicePicker: View {
    let model: SimulatorPaneModel
    let device: ServerSimulatorDevice

    var body: some View {
      Autocomplete.Menu {
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
      } label: {
        // The device and its OS, with the chevron beside the name as the Review pane's is.
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          VStack(alignment: .leading, spacing: 0) {
            Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(device.runtime.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        // The toolbar's hover highlight wraps the label's frame; give the text room inside it.
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
