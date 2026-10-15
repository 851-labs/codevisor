#if os(macOS)
  import CodevisorClient
  import SwiftUI

  public struct SimulatorDeviceCommandItems: View {
    let model: SimulatorPaneModel
    let device: ServerSimulatorDevice
    let onScreenshot: (Data, String) -> Void

    public init(
      model: SimulatorPaneModel, device: ServerSimulatorDevice, onScreenshot: @escaping (Data, String) -> Void
    ) {
      self.model = model
      self.device = device
      self.onScreenshot = onScreenshot
    }

    public var body: some View {
      Button(device.deviceType.productFamily == "Apple TV" ? "TV" : "Home") {
        SimulatorDeviceControls.press("home", on: model)
      }
      .keyboardShortcut("h", modifiers: [.command, .shift])
      if SimulatorDeviceControls.hasSoftwareKeyboard(device) {
        Button("Toggle Software Keyboard") { SimulatorDeviceControls.toggleSoftwareKeyboard(on: model) }
          .keyboardShortcut("k", modifiers: .command)
      }
      Button("Save Screenshot") {
        Task { [model, device, onScreenshot] in
          guard let data = await model.screenshot() else { return }
          onScreenshot(data, device.name)
        }
      }
      .keyboardShortcut("s", modifiers: .command)
      if SimulatorRotateButton.shown(model: model, device: device) {
        Divider()
        Button("Rotate Left") { model.rotate(clockwise: false) }
          .keyboardShortcut(.leftArrow, modifiers: .command)
        Button("Rotate Right") { model.rotate(clockwise: true) }
          .keyboardShortcut(.rightArrow, modifiers: .command)
      }
    }
  }
#endif
