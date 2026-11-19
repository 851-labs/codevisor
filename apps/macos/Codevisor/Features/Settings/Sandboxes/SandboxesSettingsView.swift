import CodevisorCore
import CodevisorUI
import SwiftUI

struct SandboxesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  let model: SandboxSettingsModel
  @State private var sheet: SandboxSettingsSheet?

  private var router: SettingsRouter { SettingsRouter.shared }

  private var client: any CodevisorServerClienting {
    environment.machines.client(for: CodevisorMachine.local.id)
  }

  var body: some View {
    Group {
      if model.hasNothingSetUp {
        SandboxEmptyState { sheet = .newProvider }
      } else {
        Form { SandboxProviderSections(model: model, sheet: $sheet) }
          .formStyle(.grouped)
      }
    }
    .settingsAddToolbarItem {
      SettingsAddButton("Add Provider") { sheet = .newProvider }
        .disabled(!model.hasLoaded)
    }
    .modifier(SandboxSettingsSheets(sheet: $sheet, model: model, client: client))
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

  private var errorShown: Binding<Bool> {
    Binding(
      get: { model.errorMessage != nil && router.panePath.isEmpty && sheet == nil },
      set: { if !$0 { model.errorMessage = nil } }
    )
  }
}
