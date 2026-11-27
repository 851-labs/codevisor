import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopSetupUpkeepIfAny: ViewModifier {
  let machineId: String
  let machineName: String
  let view: UUID
  let store: StoreOf<MachineDesktopSetup>?

  func body(content: Content) -> some View {
    if let store {
      content.modifier(
        MachineDesktopSetupUpkeep(machineId: machineId, machineName: machineName, view: view, store: store))
    } else {
      content
    }
  }
}
