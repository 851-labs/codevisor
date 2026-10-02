import CodevisorClient
import SwiftUI

/// The Simulator pane's toolbar items: which device leads, its settings and actions trail. The
/// device's own controls (Home, screenshot, rotation, posture) sit along the bottom, as in Device
/// Hub: the pane's action bar on a Mac, the bottom toolbar on an iPhone or iPad.
public struct SimulatorPaneToolbar: ToolbarContent {
  let model: SimulatorPaneModel
  /// Saves or shares a screenshot (PNG) of the device.
  let onScreenshot: (Data, String) -> Void

  public init(model: SimulatorPaneModel, onScreenshot: @escaping (Data, String) -> Void) {
    self.model = model
    self.onScreenshot = onScreenshot
  }

  public var body: some ToolbarContent {
    #if os(macOS)
      if let device = model.device {
        // In place of the window title, without a glass capsule; the toolbar's hover highlight
        // wraps the label evenly, so nothing pads it from outside.
        ToolbarItem(id: "simulator.device", placement: .navigation) {
          SimulatorDevicePicker(model: model, device: device)
        }
        .sharedBackgroundVisibility(.hidden)
        // Without a window title to push them over, settings and actions need the space.
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .primaryAction) {
          if device.isBooted { SimulatorSettingsButton(model: model) }
          SimulatorActionsMenu(model: model, device: device)
        }
      }
    #else
      if let device = model.device {
        ToolbarItem(id: "simulator.device", placement: .principal) {
          SimulatorDeviceMenu(model: model, device: device)
        }
        .sharedBackgroundVisibility(.hidden)
        // Declared before the workspace's New Tab button, so they sit to its left.
        ToolbarItemGroup(placement: .topBarTrailing) {
          if device.isBooted { SimulatorSettingsButton(model: model) }
          SimulatorActionsMenu(model: model, device: device)
        }
      }
      if let device = model.runningDevice {
        ToolbarItemGroup(placement: .bottomBar) {
          SimulatorHomeButtons(model: model, device: device)
          SimulatorScreenshotButton(model: model, device: device, onScreenshot: onScreenshot)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if SimulatorRotateButton.shown(model: model, device: device) {
          ToolbarItem(id: "simulator.rotate", placement: .bottomBar) { SimulatorRotateButton(model: model) }
        }
        if model.deviceState?.postures.isEmpty == false {
          ToolbarItem(id: "simulator.posture", placement: .bottomBar) { SimulatorPosturePicker(model: model) }
        }
      }
    #endif
  }
}

/// The Mac's simulators to switch to, grouped by kind with the running ones marked, then a
/// new one: the menu behind an iPhone's centered title.
public struct SimulatorDeviceMenuItems: View {
  let model: SimulatorPaneModel

  public init(model: SimulatorPaneModel) {
    self.model = model
  }

  public var body: some View {
    Picker("Simulator", selection: Binding(get: { model.udid ?? "" }, set: { model.choose($0) })) {
      ForEach(SimulatorFamilies.sorted(model.list?.devices ?? [])) { device in
        // A menu shows the second line as the item's subtitle.
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

#if os(iOS)
  /// An iPhone's centered title: the device and its OS, opening the device menu.
  struct SimulatorDeviceMenu: View {
    let model: SimulatorPaneModel
    let device: ServerSimulatorDevice

    var body: some View {
      Menu {
        SimulatorDeviceMenuItems(model: model)
      } label: {
        HStack(spacing: 4) {
          VStack(spacing: 0) {
            Text(device.name).font(.headline).lineLimit(1)
            Text(device.runtime.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
          Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
      }
      .accessibilityLabel("Simulator: \(device.name), \(device.runtime.name)")
    }
  }
#endif

/// Opens the device's settings: a popover on a Mac, a sheet on an iPhone or iPad.
struct SimulatorSettingsButton: View {
  let model: SimulatorPaneModel

  var body: some View {
    let showing = Binding(get: { model.showsSettings }, set: { model.showsSettings = $0 })
    Button("Device Settings", systemImage: "slider.horizontal.3") { model.showsSettings.toggle() }
      .help("Device Settings")
      #if os(macOS)
        .popover(isPresented: showing, arrowEdge: .bottom) { SimulatorSettingsView(model: model) }
      #else
        // A plain sheet, sliding up as sheets do, rather than a popover zooming out of the button.
        .sheet(isPresented: showing) { SimulatorSettingsView(model: model) }
      #endif
  }
}

/// Everything else you can do to the device: restart, shut down, rename, delete.
struct SimulatorActionsMenu: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice
  @State private var renaming = false
  @State private var confirmingDelete = false
  @State private var name = ""

  var body: some View {
    Menu("More", systemImage: "ellipsis") {
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
    .alert("Rename Simulator", isPresented: $renaming) {
      TextField("Name", text: $name)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { model.rename(to: name) }
    }
    .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete Simulator", role: .destructive) { model.perform(.delete) }
    } message: {
      Text("Its apps and data are removed from the Mac.")
    }
  }
}
