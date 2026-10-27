import CodevisorCore
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var accountDraft: SandboxAccountDraft?
  @State private var profileDraft: SandboxProfileDraft?
  @State private var removingAccount: ServerSandboxAccount?
  @State private var removingProfile: ServerSandboxProfile?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      SandboxProfilesSection(
        model: model,
        onAdd: { profileDraft = SandboxProfileDraft(provider: $0, accountId: model.accounts(for: $0.id).first?.id) },
        onEdit: { profile in
          guard let provider = model.provider(profile.provider) else { return }
          profileDraft = SandboxProfileDraft(provider: provider, profile: profile)
        },
        onDelete: { removingProfile = $0 }
      )
      SandboxAccountsSection(
        model: model,
        onAdd: { accountDraft = SandboxAccountDraft(provider: $0) },
        onEdit: { account in
          guard let provider = model.provider(account.provider) else { return }
          accountDraft = SandboxAccountDraft(provider: provider, account: account)
        },
        onDelete: { removingAccount = $0 }
      )
    }
    .formStyle(.grouped)
    .sheet(item: $accountDraft) { SandboxAccountSheet(draft: $0, model: model, client: client) }
    .sheet(item: $profileDraft) { SandboxProfileSheet(draft: $0, model: model, client: client) }
    .confirmationDialog(
      "Remove “\(removingAccount.map(model.title(of:)) ?? "")”?",
      isPresented: presence($removingAccount), titleVisibility: .visible, presenting: removingAccount
    ) { account in
      Button("Remove Account", role: .destructive) { Task { await model.delete(account, using: client) } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Codevisor forgets these credentials on all your machines.")
    }
    .confirmationDialog(
      "Delete “\(removingProfile?.name ?? "")”?",
      isPresented: presence($removingProfile), titleVisibility: .visible, presenting: removingProfile
    ) { profile in
      Button("Delete Profile", role: .destructive) { Task { await model.delete(profile, using: client) } }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text("Sandboxes already started from it keep running until their workspace is archived.")
    }
    .alert("Couldn't change sandboxes", isPresented: errorShown) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    .task(id: environment.machines.allMachines.map(\.id)) {
      await model.load(from: client, machines: reachableMachines)
    }
  }

  private var reachableMachines: [SandboxMachine] {
    environment.machines.allMachines
      .filter { environment.machines.availability(for: $0.id) == .ready }
      .map { SandboxMachine(name: $0.name, client: environment.machines.client(for: $0.id)) }
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
