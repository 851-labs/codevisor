import CodevisorCore
import SwiftUI

/// A single presenter, placed in the iOS toolbar or the macOS section footer.
public struct HarnessAddButton<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @Bindable private var model: HarnessGlobalModel
  private let icon: (String, String) -> Icon

  public init(model: HarnessGlobalModel, @ViewBuilder icon: @escaping (String, String) -> Icon) {
    self.model = model
    self.icon = icon
  }

  public var body: some View {
    Button {
      model.showsPicker = true
      Task { await model.loadCatalog(in: environment) }
    } label: {
      Label("Add Harness…", systemImage: "plus")
    }
    .font(.body)
    .accessibilityLabel("Add Harness")
    .task(id: environment.machines.allMachines.map(\.id)) { await model.loadCatalog(in: environment) }
    .sheet(isPresented: $model.showsPicker) { picker }
    #if os(iOS)
      .alert(
        "Uninstall \(model.uninstall?.name ?? "harness")?",
        isPresented: confirmsUninstall,
        presenting: model.uninstall
      ) { setting in
        uninstallActions(setting)
      } message: { _ in
        Text("Applies to machines using global settings. Chats and accounts are kept.")
      }
    #else
      .confirmationDialog(
        "Uninstall \(model.uninstall?.name ?? "harness")?",
        isPresented: confirmsUninstall,
        titleVisibility: .visible,
        presenting: model.uninstall
      ) { setting in
        uninstallActions(setting)
      } message: { _ in
        Text("Applies to machines using global settings. Chats and accounts are kept.")
      }
    #endif
  }

  private var confirmsUninstall: Binding<Bool> {
    Binding(get: { model.uninstall != nil }, set: { if !$0 { model.uninstall = nil } })
  }

  private var picker: some View {
    HarnessPickerSheet(
      harnesses: model.catalog.filter { harness in
        !HarnessFleet.settings(environment.configSync).contains(where: { $0.id == harness.id })
      },
      isLoading: model.isLoading,
      loadFailed: model.loadFailed,
      retry: { Task { await model.loadCatalog(in: environment) } },
      add: { model.add($0, in: environment) },
      icon: icon
    )
  }

  @ViewBuilder
  private func uninstallActions(_ setting: HarnessFleet.Setting) -> some View {
    Button("Uninstall", role: .destructive) {
      var next = setting
      next.installed = false
      next.enabled = false
      HarnessFleet.set(next, in: environment.configSync)
    }
    Button("Cancel", role: .cancel) {}
  }

}
