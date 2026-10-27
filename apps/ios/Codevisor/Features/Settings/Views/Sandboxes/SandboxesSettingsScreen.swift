import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var providerDraft: SandboxProviderDraft?
  @State private var profileDraft: SandboxProfileDraft?
  @State private var removingProfile: ServerSandboxProfile?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: settingsMachineId)
  }

  private var settingsMachineId: String {
    let machines = environment.machines
    if machines.availability(for: machines.selectedMachineId) == .ready { return machines.selectedMachineId }
    return reachableMachines.first?.id ?? machines.selectedMachineId
  }

  var body: some View {
    List {
      SandboxProfilesList(
        model: model,
        onEdit: edit,
        onEditProvider: editProvider,
        onDelete: { removingProfile = $0 }
      )
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Profile", systemImage: "plus") { profileDraft = SandboxProfileDraft() }
          .labelStyle(.iconOnly)
          .disabled(!model.hasLoaded)
      }
    }
    .sheet(item: $providerDraft) { SandboxProviderSheet(draft: $0, model: model, client: client, onSaved: { _ in }) }
    .sheet(item: $profileDraft) { SandboxProfileSheet(draft: $0, model: model, client: client) }
    .alert("Delete “\(removingProfile?.name ?? "")”?", isPresented: presence($removingProfile)) {
      Button("Delete", role: .destructive) {
        guard let profile = removingProfile else { return }
        Task { await model.delete(profile, using: client) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Couldn’t change sandboxes", isPresented: errorShown) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
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

  private func edit(_ profile: ServerSandboxProfile) {
    profileDraft = SandboxProfileDraft(profile: profile, vendor: model.vendor(profile.vendor))
  }

  private func editProvider(_ profile: ServerSandboxProfile) {
    guard let provider = model.provider(profile.providerId) else { return }
    providerDraft = SandboxProviderDraft(vendor: model.vendor(provider.vendor), provider: provider)
  }

  private var errorShown: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && providerDraft == nil && profileDraft == nil },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
