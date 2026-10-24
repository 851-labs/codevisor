#if DEBUG
  import CodevisorCore
  import SimulatorPane
  import SwiftUI

  struct BentoSimulatorSettings: View {
    @State private var model = SimulatorPaneModel(
      client: DemoServerClient(machine: DemoWorld.macStudio),
      preferences: SimulatorPanePreferences(udid: DemoWorld.simulator.udid), machineId: DemoWorld.macStudio.serverId,
      workspaceId: UUID(), paneId: UUID())
    @State private var hasDevice = false

    var body: some View {
      Group {
        if hasDevice {
          SimulatorSettingsView(model: model)
        } else {
          ProgressView()
        }
      }
      .task {
        await model.refresh()
        hasDevice = model.device != nil
      }
    }
  }
#endif
