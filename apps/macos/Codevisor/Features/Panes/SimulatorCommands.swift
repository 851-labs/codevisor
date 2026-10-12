import SimulatorPane
import SwiftUI

private struct SimulatorPaneKey: FocusedValueKey {
  typealias Value = SimulatorPaneModel
}

extension FocusedValues {
  /// The focused pane's simulator, if that pane is one.
  var simulatorPane: SimulatorPaneModel? {
    get { self[SimulatorPaneKey.self] }
    set { self[SimulatorPaneKey.self] = newValue }
  }
}

/// The focused simulator's device controls (Home, Save Screenshot, Rotate), with Simulator's
/// shortcuts. The menu exists only while a running simulator has focus, never as an empty or
/// disabled menu: a disabled item still swallows its key equivalent, and ⌘← ⌘→ must reach a
/// composer otherwise.
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
