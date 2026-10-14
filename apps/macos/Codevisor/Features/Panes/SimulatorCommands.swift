import SimulatorPane
import SwiftUI

private struct SimulatorPaneKey: FocusedValueKey {
  typealias Value = SimulatorPaneModel
}

extension FocusedValues {
  var simulatorPane: SimulatorPaneModel? {
    get { self[SimulatorPaneKey.self] }
    set { self[SimulatorPaneKey.self] = newValue }
  }
}

struct SimulatorCommands: Commands {
  @FocusedValue(\.simulatorPane) private var simulator

  var body: some Commands {
    if let simulator, let device = simulator.runningDevice {
      CommandMenu("Simulator") {
        SimulatorDeviceCommandItems(model: simulator, device: device) { data, name in
          AppleSimulatorPane.saveScreenshot(data, deviceName: name)
        }
      }
    }
  }
}
