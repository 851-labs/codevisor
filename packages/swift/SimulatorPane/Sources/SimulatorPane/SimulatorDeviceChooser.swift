#if os(macOS)
  import Autocomplete
  import CodevisorUI
#endif
import CodevisorClient
import SwiftUI

/// Kinds of device, in the order lists show them.
enum SimulatorFamilies {
  static let order = ["iPhone", "iPad", "Apple Watch", "Apple TV", "Apple Vision"]

  /// One list without per-kind sections: iPhones first, then iPads and so on, each kind in the
  /// order simctl lists it.
  static func sorted(_ devices: [ServerSimulatorDevice]) -> [ServerSimulatorDevice] {
    let rank = { (family: String) in order.firstIndex(of: family) ?? order.count }
    return devices.enumerated()
      .sorted { lhs, rhs in
        let left = rank(lhs.element.deviceType.productFamily), right = rank(rhs.element.deviceType.productFamily)
        return left == right ? lhs.offset < rhs.offset : left < right
      }
      .map(\.element)
  }
}

/// A pane with no device yet: the Mac's simulators to choose from. On a Mac it's the title's
/// device picker, centered on the pane as an empty File pane shows its file picker; on an iPhone or
/// iPad it's an inset grouped list, as the File pane's browser is there.
struct SimulatorDeviceChooser: View {
  let model: SimulatorPaneModel

  var body: some View { chooser }

  #if os(macOS)
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var focus = Autocomplete.InputFocus()

    private var chooser: some View {
      // Centered while it fits, scrolling when the pane is shorter (as MacFileOpenPage).
      GeometryReader { geometry in
        ScrollView {
          Autocomplete.Suggestions(query: $query, focus: focus) {
            SimulatorDevicePicker.entries(model: model)
          }
          .autocompleteStyle(Self.style)
          .autocompleteSearchLabel("Search simulators")
          .autocompleteEmptyMessage("No matching simulators", noItems: "No simulators")
          .composerGlassSurface(cornerRadius: 18)
          .padding(20)
          .frame(maxWidth: .infinity)
          .frame(minHeight: geometry.size.height)
        }
      }
      .background(theme.paneBackground)
    }

    private static let style: Autocomplete.Style = {
      var metrics = Autocomplete.Metrics.xcodeMenu
      metrics.maximumWidth = 480
      metrics.maximumHeight = 480
      return Autocomplete.Style(metrics: metrics)
    }()
  #else
    private var devices: [ServerSimulatorDevice] { SimulatorFamilies.sorted(model.list?.devices ?? []) }

    private var chooser: some View {
      List {
        Section {
          ForEach(devices) { device in
            Button {
              model.choose(device.udid)
            } label: {
              // Choosing opens the device, so it reads as a drill-in row (as the File browser's
              // folders do).
              HStack {
                SimulatorManagerRow(device: device, deleting: model.deleting.contains(device.udid))
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                  .accessibilityHidden(true)
              }
            }
          }
        }
        if !devices.isEmpty {
          Section {
            Button("Manage Simulators…", systemImage: "gearshape") { model.managingSimulators = true }
          }
        }
      }
      .listStyle(.insetGrouped)
      .contentMargins(.top, 12, for: .scrollContent)
      .overlay {
        if devices.isEmpty {
          ContentUnavailableView {
            Label("No Simulators", systemImage: "iphone")
          } description: {
            Text("This Mac has no simulators yet.")
          } actions: {
            Button("Manage Simulators…") { model.managingSimulators = true }
          }
        }
      }
      .refreshable { await model.refresh() }
    }
  #endif
}

/// Name, device type and OS for a new simulator.
struct SimulatorCreateSheet: View {
  let model: SimulatorPaneModel
  let done: () -> Void
  @State private var name = ""
  @State private var deviceType = ""
  @State private var runtime = ""

  private var deviceTypes: [ServerSimulatorDeviceType] { model.list?.deviceTypes ?? [] }
  private var runtimes: [ServerSimulatorRuntime] {
    (model.list?.runtimes ?? []).filter { $0.deviceTypeIdentifiers.contains(deviceType) }
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Name", text: $name, prompt: Text(deviceTypes.first { $0.identifier == deviceType }?.name ?? "Name"))
        Picker("Device", selection: $deviceType) {
          ForEach(SimulatorFamilies.order, id: \.self) { family in
            let types = deviceTypes.filter { $0.productFamily == family }
            if !types.isEmpty {
              Section(family) {
                ForEach(types) { Text($0.name).tag($0.identifier) }
              }
            }
          }
        }
        Picker("OS Version", selection: $runtime) {
          ForEach(runtimes) { Text($0.name).tag($0.identifier) }
        }
        .disabled(runtimes.isEmpty)
      }
      .formStyle(.grouped)
      .navigationTitle("New Simulator")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            let typeName = deviceTypes.first { $0.identifier == deviceType }?.name ?? "Simulator"
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            model.create(name: trimmed.isEmpty ? typeName : trimmed, deviceType: deviceType, runtime: runtime)
            done()
          }
          .disabled(deviceType.isEmpty || runtime.isEmpty)
        }
      }
    }
    .frame(minWidth: 380, minHeight: 260)
    .onAppear {
      if deviceType.isEmpty {
        deviceType =
          model.device?.deviceType.identifier
          ?? deviceTypes.first { $0.productFamily == "iPhone" }?.identifier ?? deviceTypes.first?.identifier ?? ""
      }
    }
    .onChange(of: deviceType, initial: true) {
      if !runtimes.contains(where: { $0.identifier == runtime }) { runtime = runtimes.last?.identifier ?? "" }
    }
  }
}
