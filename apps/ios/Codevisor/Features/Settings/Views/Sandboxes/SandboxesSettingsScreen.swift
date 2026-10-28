import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  let navigate: (SandboxSettingsNavigation) -> Void
  @State private var removingProfile: ServerSandboxProfile?

  static func machineId(in machines: MachineController) -> String {
    if machines.availability(for: machines.selectedMachineId) == .ready { return machines.selectedMachineId }
    let ready = machines.chatMachines.first { machines.availability(for: $0.id) == .ready }
    return ready?.id ?? machines.selectedMachineId
  }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: Self.machineId(in: environment.machines))
  }

  private var isFirstRun: Bool {
    model.hasLoaded && model.profiles.isEmpty && model.providers.isEmpty
  }

  var body: some View {
    List {
      if isFirstRun {
        Section("Choose a sandbox vendor") {
          SandboxVendorList(vendors: model.vendors.vendors) { vendor in
            navigate(.push(.newProvider(vendorId: vendor.id)))
          }
        }
      } else {
        SandboxProfilesList(
          model: model,
          onEdit: { navigate(.push(.editProfile(profileId: $0.id))) },
          onDelete: { removingProfile = $0 }
        )
      }
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !isFirstRun {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Add Profile", systemImage: "plus") {
            navigate(.push(model.providers.isEmpty ? .vendors : .addProfile))
          }
          .labelStyle(.iconOnly)
          .disabled(!model.hasLoaded)
        }
      }
    }
    .alert("Delete “\(removingProfile?.name ?? "")”?", isPresented: presence($removingProfile)) {
      Button("Delete", role: .destructive) {
        guard let profile = removingProfile else { return }
        Task { await model.delete(profile, using: client) }
      }
      Button("Cancel", role: .cancel) {}
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

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
