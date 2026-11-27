import CodevisorCore
import CodevisorCoreMac
import ComposableArchitecture
import SwiftUI

struct MachineDesktopInspectorCard: View {
  let machine: CodevisorMachine
  let isExpanded: Binding<Bool>
  let isActive: Bool
  let onOpen: () -> Void
  let onOpenTerminal: ((String) -> Void)?
  @Environment(AppEnvironment.self) private var environment
  @State private var view = UUID()

  var body: some View {
    if let setup {
      WorkspaceInspectorCard(
        title: "Desktop", isExpanded: isExpanded, accessory: AnyView(MachineDesktopMenu(store: setup, view: view))
      ) {
        MachineDesktopSetupCard(
          machine: machine, store: setup, sharesDesktop: sharesDesktop, isStreaming: isStreaming, onOpen: onOpen,
          onOpenTerminal: onOpenTerminal.map { open in { open(setup.terminalCommand) } }, view: view
        )
        .id(machine.id)
      }
    } else {
      WorkspaceInspectorCard(title: "Desktop", isExpanded: isExpanded) {
        MachineDesktopPreview(machine: machine, isStreaming: isStreaming, onOpen: onOpen)
          .id(machine.id)
      }
    }
  }

  private var isStreaming: Bool { isActive && isExpanded.wrappedValue }

  private var sharesDesktop: Bool { environment.machines.desktopMachine(for: machine.id) != nil }

  private var setup: StoreOf<MachineDesktopSetup>? {
    guard environment.machines.linuxDesktopMachine(for: machine.id) != nil else { return nil }

    return MachineDesktopSetups.shared.store(for: machine.id, named: machine.name, machines: environment.machines)
  }
}
