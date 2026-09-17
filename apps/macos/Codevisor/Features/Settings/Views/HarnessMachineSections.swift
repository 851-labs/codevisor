import CodevisorCore
import CodevisorUI
import SwiftUI

/// Pure section and row rendering for a machine's harness catalog.
struct HarnessMachineSections: View {
  @Environment(\.theme) private var theme

  let model: HarnessMachineModel
  let onScan: () -> Void
  let onAuthenticate: (ServerHarness, Bool) -> Void
  let onShowDetail: (ServerHarness) -> Void
  let onUninstall: (ServerHarness) -> Void
  let onReset: (ServerHarness) -> Void
  let onEditCustom: (String?) -> Void

  var body: some View {
    Group {
      installedSection
      if !model.notInstalledHarnesses.isEmpty {
        Section("Not installed") {
          ForEach(model.notInstalledHarnesses, id: \.id) { harness in
            notInstalledRow(harness)
          }
        }
      }
    }
  }

  private var installedSection: some View {
    Section {
      if model.isScanning, model.harnesses.isEmpty {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning for harnesses…").foregroundStyle(.secondary)
        }
      } else {
        if let error = model.catalogErrorMessage {
          // A failed refresh keeps the last useful catalog visible.
          Text("Couldn't refresh this machine's harnesses. Check its status, then try again.")
            .foregroundStyle(.secondary)
            .help(error)
        }
        if model.installedHarnesses.isEmpty {
          Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(model.installedHarnesses, id: \.id) { harness in
            installedRow(harness)
          }
        }
      }
    } header: {
      Text("Installed")
    } footer: {
      SettingsListActions {
        Button(action: onScan) {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .settingsActionTint(theme)
        .disabled(model.isScanning)
        Button("Add Custom Harness…") { onEditCustom(nil) }
          .settingsActionTint(theme)
      }
    }
  }

  private func installedRow(_ harness: ServerHarness) -> some View {
    let state = HarnessRowState.machine(harness)
    return HarnessSettingsRow(
      name: harness.name, state: state,
      isEnabled: Binding(
        get: { model.harness(id: harness.id)?.isDesiredEnabled ?? harness.isDesiredEnabled },
        set: { enabled in Task { await model.setDesiredEnabled(id: harness.id, enabled: enabled) } }),
      isChanging: model.isChangingPreference(for: harness.id),
      signIn: { onAuthenticate(harness, true) }
    ) {
      HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 18)
    } actions: {
      if state.showsAccounts {
        Button("Accounts…") { onAuthenticate(harness, false) }
      }
      if harness.updateInfo?.updateAvailable == true {
        Button("Update") { Task { await model.updateHarness(id: harness.id) } }
          .disabled(harness.isLifecycleBusy || model.isStartingUpdate(for: harness.id))
      }
      if harness.hasOverride {
        Button("Use Global Setting") { onReset(harness) }.disabled(harness.isLifecycleBusy)
      }
      if harness.source == "custom" {
        Button("Edit…") { onEditCustom(harness.id) }
      } else {
        Button("Get Info…") { onShowDetail(harness) }
      }
      Divider()
      Button("Uninstall…", role: .destructive) { onUninstall(harness) }.disabled(harness.isLifecycleBusy)
    }
  }

  @ViewBuilder
  private func notInstalledRow(_ harness: ServerHarness) -> some View {
    if harness.source == "custom" {
      HStack(spacing: 10) {
        HarnessInstallHintRow(harness: harness)
        Button("Edit…") { onEditCustom(harness.id) }
          .settingsActionTint(theme)
      }
    } else {
      VStack(alignment: .leading, spacing: 4) {
        HarnessInstallHintRow(harness: harness)
        if harness.hasOverride {
          HStack {
            Text(harness.settingsSummary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Use Global Setting") { onReset(harness) }
              .disabled(harness.isLifecycleBusy)
          }
        }
      }
    }
  }
}
