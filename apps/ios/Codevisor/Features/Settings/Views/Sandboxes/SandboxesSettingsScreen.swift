import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var sheet: SandboxSettingsSheet?

  static func machineId(in machines: MachineController) -> String {
    if machines.availability(for: machines.selectedMachineId) == .ready { return machines.selectedMachineId }
    let ready = machines.chatMachines.first { machines.availability(for: $0.id) == .ready }
    return ready?.id ?? machines.selectedMachineId
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: Self.machineId(in: environment.machines))
  }

  var body: some View {
    List {
      if model.hasNothingSetUp {
        SandboxProviderSetupSection(vendors: model.vendors.vendors) { sheet = .newProvider(vendorId: $0.id) }
      } else {
        SandboxProviderSections(model: model, sheet: $sheet) { navigate(.push(.editProfile(profileId: $0.id))) }
      }
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Provider", systemImage: "plus") { sheet = .newProvider(vendorId: nil) }
          .labelStyle(.iconOnly)
          .disabled(!model.hasLoaded)
      }
    }
    .modifier(SandboxSettingsSheets(sheet: $sheet, model: model, client: client))
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
