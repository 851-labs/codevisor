import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  @State private var adding = false

  private var router: SettingsRouter { SettingsRouter.shared }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  private var isEmpty: Bool {
    model.hasLoaded && model.profiles.isEmpty
  }

  var body: some View {
    Group {
      if isEmpty {
        SandboxEmptyState { adding = true }
      } else {
        Form { profilesSection }
          .formStyle(.grouped)
      }
    }
    .sheet(isPresented: $adding) {
      SandboxNewProfileSheet(model: model, client: client)
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
      ForEach(model.profiles) { profile in
        NavigationLink(value: SettingsPaneRoute.sandbox(.editProfile(profileId: profile.id))) {
          SandboxProfileRow(profile: profile)
        }
      }
    } header: {
      Text("Profiles")
    } footer: {
      SettingsListActions {
        Button {
          adding = true
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
      get: { model.errorMessage != nil && router.panePath.isEmpty && !adding },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }
}
