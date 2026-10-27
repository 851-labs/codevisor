import CodevisorCore
import SwiftUI

struct SandboxesSettingsScreen: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var accountDraft: SandboxAccountDraft?
  @State private var profileDraft: SandboxProfileDraft?
  @State private var removingAccount: ServerSandboxAccount?
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
        onAdd: { profileDraft = SandboxProfileDraft(provider: $0, accountId: model.accounts(for: $0.id).first?.id) },
        onEdit: edit,
        onDelete: { removingProfile = $0 }
      )
      SandboxAccountsList(
        model: model,
        onAdd: { accountDraft = SandboxAccountDraft(provider: $0) },
        onEdit: edit,
        onDelete: { removingAccount = $0 }
      )
    }
    .navigationTitle("Sandboxes")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $accountDraft) { SandboxAccountEditor(draft: $0, model: model, client: client) }
    .sheet(item: $profileDraft) { SandboxProfileEditor(draft: $0, model: model, client: client) }
    .alert("Remove “\(removingAccount.map(model.title(of:)) ?? "")”?", isPresented: presence($removingAccount)) {
      Button("Remove", role: .destructive) {
        guard let account = removingAccount else { return }
        Task { await model.delete(account, using: client) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Codevisor forgets these credentials on all your machines.")
    }
    .alert("Delete “\(removingProfile?.name ?? "")”?", isPresented: presence($removingProfile)) {
      Button("Delete", role: .destructive) {
        guard let profile = removingProfile else { return }
        Task { await model.delete(profile, using: client) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Sandboxes already started from it keep running until their workspace is archived.")
    }
    .alert("Couldn’t change sandboxes", isPresented: errorShown) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    .task(id: reachableMachines.map(\.id)) {
      await model.load(from: client, machines: reachableMachines.map(sandboxMachine))
    }
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

  private func edit(_ account: ServerSandboxAccount) {
    guard let provider = model.provider(account.provider) else { return }
    accountDraft = SandboxAccountDraft(provider: provider, account: account)
  }

  private var errorShown: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && accountDraft == nil && profileDraft == nil },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
