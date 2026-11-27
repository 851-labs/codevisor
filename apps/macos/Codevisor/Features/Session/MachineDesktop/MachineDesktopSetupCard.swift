import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopSetupCard: View {
  let machine: CodevisorMachine
  let store: StoreOf<MachineDesktopSetup>
  let sharesDesktop: Bool
  let isStreaming: Bool
  let onOpen: () -> Void
  let onOpenTerminal: (() -> Void)?
  let view: UUID

  var body: some View {
    ZStack {
      if store.state.showsDesktop(sharedByMachine: sharesDesktop) {
        MachineDesktopPreview(
          machine: machine, isStreaming: isStreaming, onOpen: onOpen, onFailure: { store.send(.machineChanged) })
      } else {
        MachineDesktopSetupStatus(store: store, view: view, size: .card, onOpenTerminal: onOpenTerminal)
          .frame(minHeight: 120)
      }
    }
    .containerValue(\.fillsWorkspaceInspectorCardRow, true)
    .modifier(
      MachineDesktopSetupUpkeep(machineId: machine.id, machineName: machine.name, view: view, store: store))
  }
}
