import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @State private var model = SandboxSettingsModel()
  @State private var providerDraft: SandboxProviderDraft?
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
            hasProvider: model.provider(profile.providerId) != nil,
            onEdit: { edit(profile) },
            onEditProvider: { editProvider(of: profile) },
            onDelete: { removingProfile = profile }
          )
        }
      } header: {
        Text("Profiles")
      } footer: {
        SettingsListActions {
          Button {
            profileDraft = SandboxProfileDraft()
          } label: {
            Label("Add Profile…", systemImage: "plus")
          }
          .disabled(!model.hasLoaded)
        }
      }
    }
    .formStyle(.grouped)
    .sheet(item: $providerDraft) { SandboxProviderSheet(draft: $0, model: model, client: client, onSaved: { _ in }) }
    .sheet(item: $profileDraft) { SandboxProfileSheet(draft: $0, model: model, client: client) }
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
    profileDraft = SandboxProfileDraft(profile: profile, vendor: model.vendor(profile.vendor))
  }

  private func editProvider(of profile: ServerSandboxProfile) {
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
