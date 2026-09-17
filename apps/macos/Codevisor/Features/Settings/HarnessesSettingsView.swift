import CodevisorCore
import CodevisorUI
import SwiftUI

/// Shared desired settings, with machine overrides beneath.
struct HarnessesSettingsView: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  @State private var globalModel = HarnessGlobalModel()
  @State private var accountsSetting: HarnessAccountsPresentation<HarnessFleet.Setting>?

  var body: some View {
    Form {
      HarnessGlobalSection(
        model: globalModel,
        onAccounts: { setting, signIn in
          accountsSetting = .init(setting, startsSignIn: signIn)
        }
      ) { id, symbol in
        HarnessIcon(harnessId: id, fallbackSymbolName: symbol, size: 18)
      }
      Section("Machines") {
        ForEach(environment.machines.allMachines) { machine in
          NavigationLink(value: SettingsPaneRoute.machine(MachinePaneRoute(pane: .harnesses, machineId: machine.id))) {
            HStack {
              Text(machine.name)
              Spacer()
              badge(machine).view.font(.callout)
            }
          }
        }
      }
    }
    .settingsPaneFormStyle(theme)
    .sheet(item: $accountsSetting) { presentation in
      let setting = presentation.selection
      HarnessAccountsSheet(harnessId: setting.id, harnessName: setting.name, startsSignIn: presentation.startsSignIn) {
        machineId, harness, request in
        HarnessAuthenticationView(
          harness: harness, onChange: { _ in },
          showsHeader: false,
          signInRequest: request
        )
        .environment(\.settingsMachineId, machineId)
      }
    }
    .background {
      if !theme.isSystem { theme.windowBackground }
    }
  }

  /// The disclosure-row badge, from the machine's own readiness report:
  /// a harness waiting on sign-in needs the user; a machine with no
  /// report yet is still converging.
  private func badge(_ machine: CodevisorMachine) -> MachineSyncBadge {
    if environment.machines.statusByMachineId[machine.id]?.isReachable == false {
      return .attention("Unreachable")
    }
    guard let key = environment.machines.syncKey(forMachineId: machine.id),
      let rows = HarnessFleet.readiness(environment.configSync)[key]
    else { return .syncing }
    if rows.contains(where: { $0.state == "signInRequired" }) {
      return .attention("Sign in required")
    }
    if rows.contains(where: { $0.state == "blocked" }) { return .attention("Needs attention") }
    if !HarnessFleet.pendingChanges(environment.configSync, machineKey: key).isEmpty { return .syncing }
    let count = HarnessFleet.overrideCount(environment.configSync, machineKey: key)
    if count > 0 { return .overrides(count) }
    return .synced
  }
}

#Preview("Harnesses") {
  HarnessesSettingsView()
    .environment(AppEnvironment.preview())
    .frame(width: 520, height: 420)
}
