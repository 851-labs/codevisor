import CodevisorClient
import CodevisorUI
import SwiftUI

public struct SimulatorPaneToolbar: ToolbarContent {
  let model: SimulatorPaneModel
  let onScreenshot: (Data, String) -> Void

  public init(model: SimulatorPaneModel, onScreenshot: @escaping (Data, String) -> Void) {
    self.model = model
    self.onScreenshot = onScreenshot
  }

  public var body: some ToolbarContent {
    #if os(macOS)
      if let device = model.device {
        ToolbarItem(id: "simulator.device", placement: .navigation) {
          SimulatorDevicePicker(model: model, device: device)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
          if device.isBooted { SimulatorSettingsButton(model: model) }
          SimulatorActionsMenu(model: model, device: device)
        }
      }
    #else
      if let device = model.device {
        ToolbarItem(id: "simulator.actions", placement: .topBarTrailing) {
          SimulatorActionsMenu(model: model, device: device)
        }
      }
      if let device = model.runningDevice {
        ToolbarItemGroup(placement: .bottomBar) {
          SimulatorHomeButtons(model: model, device: device)
          if SimulatorDeviceControls.hasSoftwareKeyboard(device) {
            SimulatorSoftwareKeyboardButton(model: model)
          }
          SimulatorScreenshotButton(model: model, device: device, onScreenshot: onScreenshot)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if SimulatorRotateButton.shown(model: model, device: device) {
          ToolbarItem(id: "simulator.rotate", placement: .bottomBar) { SimulatorRotateButton(model: model) }
        }
        if model.deviceState?.postures.isEmpty == false {
          ToolbarItem(id: "simulator.posture", placement: .bottomBar) {
            HStack(spacing: 4) { SimulatorPostureButtons(model: model) }
              .labelStyle(.iconOnly)
          }
        }
      }
    #endif
  }
}

public struct SimulatorDeviceMenuItems: View {
  let model: SimulatorPaneModel

  public init(model: SimulatorPaneModel) {
    self.model = model
  }

  public var body: some View {
    Picker("Simulator", selection: Binding(get: { model.udid ?? "" }, set: { model.choose($0) })) {
      ForEach(SimulatorFamilies.sorted(model.list?.devices ?? [])) { device in
        VStack(alignment: .leading) {
          Text(device.name)
          Text(device.isBooted ? "\(device.runtime.name) · Running" : device.runtime.name)
        }
        .tag(device.udid)
      }
    }
    .pickerStyle(.inline)
    Divider()
    Button("Manage Simulators…", systemImage: "gearshape") { model.managingSimulators = true }
  }
}

#if os(macOS)
  struct SimulatorSettingsButton: View {
    let model: SimulatorPaneModel

    var body: some View {
      let showing = Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })
      Button("Device Settings", systemImage: "slider.horizontal.3") { model.showsSettings.toggle() }
        .help("Device Settings")
        .popover(isPresented: showing, arrowEdge: .bottom) { SimulatorSettingsView(model: model) }
    }
  }
#endif

struct SimulatorActionsMenu: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice
  @State private var renaming = false
  @State private var confirmingDelete = false
  @State private var name = ""

  var body: some View {
    Menu("More", systemImage: "ellipsis") {
      #if os(iOS)
        if device.isBooted {
          Button("Device Settings", systemImage: "slider.horizontal.3") { model.showsSettings = true }
          Divider()
        }
      #endif
      if device.isBooted {
        Button("Restart", systemImage: "arrow.clockwise") { model.perform(.restart) }
        Button("Shut Down", systemImage: "power") { model.perform(.shutdown) }
      } else if device.isShutdown {
        Button("Start", systemImage: "play.fill") { model.perform(.boot) }
      }
      Divider()
      Button("Rename…", systemImage: "pencil") {
        name = device.name
        renaming = true
      }
      Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }
    .menuIndicator(.hidden)
    .help("More")
    #if os(iOS)
      .sheet(isPresented: Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })) {
        SimulatorSettingsView(model: model)
      }
    #endif
    .alert("Rename Simulator", isPresented: $renaming) {
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { model.rename(to: name) }
    }
    .focusesAlertTextField(when: renaming)
    .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete Simulator", role: .destructive) { model.perform(.delete) }
    } message: {
      Text("Its apps and data are removed from the Mac.")
    }
  }
}
