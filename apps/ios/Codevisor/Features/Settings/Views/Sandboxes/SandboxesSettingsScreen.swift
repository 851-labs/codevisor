import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var adding = false

  static func machineId(in machines: MachineController) -> String {
    if machines.availability(for: machines.selectedMachineId) == .ready { return machines.selectedMachineId }
    let ready = machines.chatMachines.first { machines.availability(for: $0.id) == .ready }
    return ready?.id ?? machines.selectedMachineId
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: Self.machineId(in: environment.machines))
  }

  private var isEmpty: Bool {
    model.hasLoaded && model.profiles.isEmpty
  }

  var body: some View {
    Group {
      if isEmpty {
        SandboxEmptyState { adding = true }
      } else {
        List {
          SandboxProfilesList(model: model) { navigate(.push(.editProfile(profileId: $0.id))) }
        }
      }
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add Profile", systemImage: "plus") { adding = true }
            .labelStyle(.iconOnly)
            .disabled(!model.hasLoaded)
        }
      }
    }
    .sheet(isPresented: $adding) {
      SandboxNewProfileSheet(model: model, client: client)
    }
    .task(id: reloadKey) {
      await model.load(from: client, machines: reachableMachines.map(sandboxMachine))
    }
  }

  private var reloadKey: [String] {
    let revisions = SandboxSettingsModel.syncNamespaces.map { environment.configSync.revisionsByNamespace[$0] ?? 0 }
    return reachableMachines.map(\.id) + revisions.map(String.init)
  }

  private var reachableMachines: [CodevisorMachine] {
    environment.machines.chatMachines.filter { environment.machines.availability(for: $0.id) == .ready }
  }

  private func sandboxMachine(_ machine: CodevisorMachine) -> SandboxMachine {
    SandboxMachine(name: machine.name, client: environment.machines.client(for: machine.id))
  }
}
