import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var isAdding = false
  @State private var accountDraft: SandboxAccountDraft?
  @State private var profileDraft: SandboxProfileDraft?
  @State private var removingProfile: ServerSandboxProfile?

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Form {
      Section {
        if model.profiles.isEmpty, model.hasLoaded {
          Text("No Profiles")
            .foregroundStyle(.secondary)
        }
        ForEach(model.profiles) { profile in
          SandboxProfileRow(
            profile: profile,
            isUntested: model.provider(profile.provider)?.tested == false,
            hasAccount: model.account(of: profile) != nil,
            onEdit: { edit(profile) },
            onEditAccount: { editAccount(of: profile) },
            onDelete: { removingProfile = profile }
          )
        }
      } header: {
        Text("Profiles")
      } footer: {
        SettingsListActions {
          Button {
            isAdding = true
          } label: {
            Label("Add Profile…", systemImage: "plus")
          }
          .disabled(!model.hasLoaded)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(isPresented: $isAdding) { SandboxAddProfileSheet(model: model, client: client) }
    .sheet(item: $accountDraft) { SandboxAccountEditSheet(draft: $0, model: model, client: client) }
    .sheet(item: $profileDraft) { SandboxProfileEditSheet(draft: $0, model: model, client: client) }
    .confirmationDialog(
      "Delete “\(removingProfile?.name ?? "")”?",
      isPresented: presence($removingProfile), titleVisibility: .visible, presenting: removingProfile
    ) { profile in
      Button("Delete", role: .destructive) { Task { await model.delete(profile, using: client) } }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Couldn’t change sandboxes", isPresented: errorShown) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(model.errorMessage ?? "")
    }
    .task(id: reloadKey) {
      await model.load(from: client, machines: reachableMachines)
    }
  }

  private var reloadKey: [String] {
    let revisions = SandboxSettingsModel.syncNamespaces.map { environment.configSync.revisionsByNamespace[$0] ?? 0 }
    return environment.machines.allMachines.map(\.id) + revisions.map(String.init)
  }

  private var reachableMachines: [SandboxMachine] {
    environment.machines.allMachines
      .filter { environment.machines.availability(for: $0.id) == .ready }
      .map { SandboxMachine(name: $0.name, client: environment.machines.client(for: $0.id)) }
  }

  private func edit(_ profile: ServerSandboxProfile) {
    guard let provider = model.provider(profile.provider) else { return }
    profileDraft = SandboxProfileDraft(provider: provider, profile: profile)
  }

  private func editAccount(of profile: ServerSandboxProfile) {
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
