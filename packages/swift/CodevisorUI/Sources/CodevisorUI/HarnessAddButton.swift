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
    Group {
      #if os(macOS)
        HarnessAddMenu(
          isPresented: $model.showsPicker,
          harnesses: availableHarnesses,
          isLoading: model.isLoading,
          loadFailed: model.loadFailed,
          retry: { Task { await model.loadCatalog(in: environment) } },
          add: { model.add($0, in: environment) },
          icon: icon
        )
      #else
        Button {
          model.showsPicker = true
        } label: {
          Label("Add Harness…", systemImage: "plus")
        }
        .sheet(isPresented: $model.showsPicker) { picker }
      #endif
    }
    .font(.body)
    .accessibilityLabel("Add Harness")
    .task(id: environment.machines.allMachines.map(\.id)) { await model.loadCatalog(in: environment) }
    .onChange(of: model.showsPicker) { _, isPresented in
      if isPresented { Task { await model.loadCatalog(in: environment) } }
    }
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
  }

  private var confirmsUninstall: Binding<Bool> {
    Binding(get: { model.uninstall != nil }, set: { if !$0 { model.uninstall = nil } })
  }

  private var availableHarnesses: [ServerHarness] {
    model.catalog.filter { harness in
      !HarnessFleet.settings(environment.configSync).contains(where: { $0.id == harness.id })
    }
  }

  #if os(iOS)
    private var picker: some View {
      HarnessPickerSheet(
        harnesses: availableHarnesses,
        isLoading: model.isLoading,
        loadFailed: model.loadFailed,
        retry: { Task { await model.loadCatalog(in: environment) } },
        add: { model.add($0, in: environment) },
        icon: icon
      )
    }
  #endif

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
