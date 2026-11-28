import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspaceMachineAttentionView: View {
  let attention: MachineAttention
  let machineId: String
  let machineName: String
  @State private var settingsDestination: SettingsDestination?

  var body: some View {
    MachineAttentionCard(attention, machineName: machineName) {
      settingsDestination = .machines(focusedMachineID: machineId)
    }
    .sheet(item: $settingsDestination) { destination in
      SettingsSheet(initialDestination: destination)
    }
  }
}
