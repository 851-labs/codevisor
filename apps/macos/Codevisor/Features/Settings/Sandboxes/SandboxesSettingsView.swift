import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  @State private var removingProfile: ServerSandboxProfile?

  private var router: SettingsRouter { SettingsRouter.shared }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  private var isFirstRun: Bool {
    model.hasLoaded && model.profiles.isEmpty && model.providers.isEmpty
  }

  var body: some View {
    Form {
      if isFirstRun {
        Section("Choose a sandbox vendor") {
          SandboxVendorList(vendors: model.vendors.vendors) { vendor in
            router.navigate(.push(.newProvider(vendorId: vendor.id)))
          }
        }
      } else {
        profilesSection
      }
    }
    .formStyle(.grouped)
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

  private var profilesSection: some View {
    Section {
      if model.profiles.isEmpty, model.hasLoaded {
        Text("No Profiles")
          .foregroundStyle(.secondary)
      }
      ForEach(model.profiles) { profile in
        SandboxProfileRow(
          profile: profile,
          onEdit: { router.navigate(.push(.editProfile(profileId: profile.id))) },
          onDelete: { removingProfile = profile }
        )
      }
    } header: {
      Text("Profiles")
    } footer: {
      SettingsListActions {
        Button {
          router.navigate(.push(model.providers.isEmpty ? .vendors : .addProfile))
        } label: {
          Label("Add Profile…", systemImage: "plus")
        }
        .disabled(!model.hasLoaded)
      }
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

  private var errorShown: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && router.panePath.isEmpty },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }

  private func presence<Value>(_ state: Binding<Value?>) -> Binding<Bool> {
    Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
  }
}
