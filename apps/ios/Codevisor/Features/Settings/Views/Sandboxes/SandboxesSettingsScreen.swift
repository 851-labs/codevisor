import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var isAdding = false
  @State private var accountDraft: SandboxAccountDraft?
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
        onEditAccount: editAccount,
        onDelete: { removingProfile = $0 }
      )
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Add Profile", systemImage: "plus") { isAdding = true }
          .labelStyle(.iconOnly)
          .disabled(!model.hasLoaded)
      }
    }
    .sheet(isPresented: $isAdding) { SandboxAddProfileSheet(model: model, client: client) }
    .sheet(item: $accountDraft) { SandboxAccountEditSheet(draft: $0, model: model, client: client) }
    .sheet(item: $profileDraft) { SandboxProfileEditSheet(draft: $0, model: model, client: client) }
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
    guard let provider = model.provider(profile.provider) else { return }
    profileDraft = SandboxProfileDraft(provider: provider, profile: profile)
  }

  private func editAccount(_ profile: ServerSandboxProfile) {
    guard let account = model.account(of: profile), let provider = model.provider(account.provider) else { return }
    accountDraft = SandboxAccountDraft(provider: provider, account: account)
  }

  private var errorShown: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && !isAdding && accountDraft == nil && profileDraft == nil },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
