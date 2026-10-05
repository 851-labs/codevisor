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
      // The device is the screen's title, and its menu the title menu (see the workspace screen);
      // settings live in the actions menu, declared before the workspace's New Tab button.
      if let device = model.device {
        ToolbarItem(id: "simulator.actions", placement: .topBarTrailing) {
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

/// The Mac's simulators to switch to, iPhones first with the running ones marked, then Manage
/// Simulators: an iPhone or iPad's title menu.
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

#if os(macOS)
  /// Opens the device's settings in a popover. (On an iPhone or iPad they're in the actions menu.)
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

/// Everything else you can do to the device: restart, shut down, rename, delete (and, on an
/// iPhone or iPad, its settings).
struct SimulatorActionsMenu: View {
  let model: SimulatorPaneModel
  let device: ServerSimulatorDevice
  @State private var renaming = false
  @State private var confirmingDelete = false
  @State private var name = ""

  var body: some View {
    Menu("More", systemImage: "ellipsis") {
      #if os(iOS)
        // On an iPhone or iPad the bar has no room for a separate settings button.
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
    .confirmationDialog("Delete \(device.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Delete Simulator", role: .destructive) { model.perform(.delete) }
    } message: {
      Text("Its apps and data are removed from the Mac.")
    }
  }
}
