import CodevisorCore
import CodevisorUI
import SwiftUI

/// Shares row presentation and request ordering with the macOS machine list.
struct HarnessMachineSections: View {
  @Environment(AppEnvironment.self) private var environment
  let machine: CodevisorMachine
  let model: HarnessMachineModel
  let presentAccounts: (ServerHarness, Bool) -> Void
  let requestUninstall: (ServerHarness) -> Void
  let resetOverride: (ServerHarness) -> Void
  @State private var showsAvailableToInstall = true

  var body: some View {
    Group {
      if model.isScanning, model.harnesses.isEmpty {
        Section { ProgressView().frame(maxWidth: .infinity) }
      }
      if let error = model.catalogErrorMessage {
        Section {
          Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
          Button("Try Again") { Task { await model.refresh() } }
        }
      }
      if !model.installedHarnesses.isEmpty {
        Section {
          ForEach(model.installedHarnesses, id: \.id) { harness in installedRow(harness) }
        }
      }
      if !model.notInstalledHarnesses.isEmpty {
        Section {
          DisclosureGroup("Available to Install", isExpanded: $showsAvailableToInstall) {
            ForEach(model.notInstalledHarnesses, id: \.id) { harness in availableRow(harness) }
          }
        }
      }
    }
  }

  private func installedRow(_ harness: ServerHarness) -> some View {
    let state = HarnessRowState.machine(harness)
    return HarnessSettingsRow(
      name: harness.name, state: state,
      isEnabled: Binding(
        get: { harness.isDesiredEnabled },
        set: { enabled in Task { await model.setDesiredEnabled(id: harness.id, enabled: enabled) } }),
      isChanging: model.isChangingPreference(for: harness.id) || model.isStartingUpdate(for: harness.id),
      signIn: { presentAccounts(harness, true) }
    ) {
      HarnessIconView(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 22)
    } actions: {
      if state.showsAccounts {
        Button("Accounts…", systemImage: "person.crop.circle") { presentAccounts(harness, false) }
      }
      if harness.updateInfo?.updateAvailable == true {
        Button("Update", systemImage: "arrow.down.circle") { Task { await model.updateHarness(id: harness.id) } }
          .disabled(harness.isLifecycleBusy || model.isStartingUpdate(for: harness.id))
      }
      if harness.hasOverride {
        Button("Use Global Setting") { resetOverride(harness) }
          .disabled(harness.isLifecycleBusy || model.isChangingPreference(for: harness.id))
      }
      NavigationLink {
        HarnessDetailScreen(machine: machine, harness: harness) { model.replaceHarness($0) }
      } label: {
        Label("Get Info", systemImage: "info.circle")
      }
      Divider()
      Button("Uninstall…", role: .destructive) { requestUninstall(harness) }
        .disabled(harness.isLifecycleBusy || model.isStartingUpdate(for: harness.id))
    }
  }

  @ViewBuilder private func availableRow(_ harness: ServerHarness) -> some View {
    if harness.isLifecycleBusy {
      HStack {
        label(harness)
        Spacer()
        ProgressView().controlSize(.small)
      }
    } else {
      NavigationLink {
        HarnessInstallScreen(harness: harness, machine: machine) { started, methodId in
          var updated = harness
          let lifecycle =
            started.lifecycle
            ?? ServerHarnessLifecycleState(
              phase: "installing", methodId: methodId, terminalId: started.terminalId)
          updated.lifecycle = lifecycle
          model.replaceHarness(updated)
          environment.setHarnessLifecycle(lifecycle, harnessId: harness.id, onServer: machine.id)
          environment.harnessCatalogDidChange(onServer: machine.id)
        }
      } label: {
        label(harness)
      }
      if harness.hasOverride {
        Button("Use Global Setting") { resetOverride(harness) }
      }
    }
  }

  private func label(_ harness: ServerHarness) -> some View {
    HStack(spacing: 10) {
      HarnessIconView(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 22)
      Text(harness.name)
    }.padding(.vertical, 4)
  }

}

struct HarnessMachineAccountsSheet: View {
  @Environment(\.dismiss) private var dismiss
  let machine: CodevisorMachine
  let harness: ServerHarness
  let startsSignIn: Bool

  var body: some View {
    NavigationStack {
      HarnessAuthenticationScreen(
        serverId: machine.id, harness: harness,
        signInRequest: startsSignIn ? HarnessMachineSignIn(profileId: harness.id == "opencode" ? "default" : nil) : nil
      )
      .navigationTitle("\(harness.name) Accounts")
      .navigationBarTitleDisplayMode(.inline)
    }
    .environment(\.harnessAccountsDismiss, { dismiss() })
  }
}
