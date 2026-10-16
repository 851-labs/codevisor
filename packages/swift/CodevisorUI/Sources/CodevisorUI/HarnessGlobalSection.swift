import CodevisorCore
import SwiftUI

public struct HarnessGlobalSection<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: HarnessGlobalModel
  private let icon: (String, String) -> Icon
  private let onAccounts: (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void
  private let onSignIn: (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void

  public init(
    model: HarnessGlobalModel,
    onAccounts: @escaping (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void,
    onSignIn: @escaping (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void,
    @ViewBuilder icon: @escaping (String, String) -> Icon
  ) {
    self.model = model
    self.onAccounts = onAccounts
    self.onSignIn = onSignIn
    self.icon = icon
  }

  public var body: some View {
    let machines = HarnessFleet.fleetMachines(environment.machines)
    let catalog = HarnessFleet.catalog(environment.configSync)
    Section {
      ForEach(HarnessFleet.settings(environment.configSync, catalog: catalog)) { setting in
        HarnessFleetRow(
          setting: setting, machines: machines, model: model,
          authRequired: catalog.first { $0.id == setting.id }?.authRequired ?? true,
          onAccounts: onAccounts, onSignIn: onSignIn
        ) {
          icon(setting.id, setting.symbolName)
        }
      }
    } footer: {
      #if os(macOS)
        HarnessAddButton(model: model, icon: icon)
      #endif
    }
  }
}

extension HarnessFleet {
  static func settings(_ sync: ConfigSync, catalog: [CatalogEntry]) -> [Setting] {
    settings(sync).map { setting in
      guard let harness = catalog.first(where: { $0.id == setting.id }) else { return setting }
      var result = setting
      result.name = harness.name
      result.symbolName = harness.symbolName
      return result
    }
  }
}

private struct HarnessFleetRow<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  let setting: HarnessFleet.Setting
  let machines: [HarnessFleet.FleetMachine]
  let model: HarnessGlobalModel
  let authRequired: Bool
  let onAccounts: (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void
  let onSignIn: (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void
  @ViewBuilder let icon: () -> Icon

  var body: some View {
    let sharesAccounts = HarnessRowState.sharesFleetAccounts(harnessId: setting.id)
    let shared = HarnessRowState.shared(
      harnessId: setting.id, sync: environment.configSync, authRequired: authRequired)
    let signedInAt =
      sharesAccounts
      ? HarnessRowState.latestSharedSignIn(harnessId: setting.id, sync: environment.configSync) : nil
    let sharedSignIn: HarnessFleet.SharedSignIn =
      !sharesAccounts
      ? .notShared
      : shared.needsSignIn ? .pending : signedInAt.map { .signedIn(at: $0) } ?? .unresolved
    let status = HarnessFleet.status(
      harnessId: setting.id, sync: environment.configSync, machines: machines, sharedSignIn: sharedSignIn)
    let live = setting.enabled
    let single = live && machines.count == 1 ? status.machines.first : nil
    let actions = HarnessMachineActions(
      signIn: sharesAccounts ? nil : { onSignIn($0, setting.id, true) },
      accounts: sharesAccounts || !shared.supportsAccounts ? nil : { onSignIn($0, setting.id, false) })
    let state = HarnessRowState(
      needsSignIn: live && sharesAccounts && shared.needsSignIn,
      supportsAccounts: sharesAccounts && shared.supportsAccounts)
    HarnessSettingsRow(
      name: setting.name, state: state,
      isEnabled: Binding(
        get: { setting.enabled },
        set: { enabled in
          var next = setting
          next.enabled = enabled
          HarnessFleet.set(next, in: environment.configSync)
        }),
      signIn: { onAccounts(setting, true) }
    ) {
      icon()
    } accessory: {
      if state.showsAccounts {
        Button("Accounts…") { onAccounts(setting, false) }
          .harnessRowButton()
      }
      if let single {
        HarnessMachineActionButton(row: single, harnessName: setting.name, actions: actions)
        if single.status.isBusy || single.status.needsAttention {
          HarnessMachineMark(
            status: single.status,
            details: HarnessMachineActionButton.details(row: single, harnessName: setting.name))
        }
      }
    } actions: {
      Button("Uninstall…", role: .destructive) { model.uninstall = setting }
    }
    if live, machines.count > 1 {
      ForEach(status.machines) { row in
        HarnessMachineRow(row: row, harnessName: setting.name, actions: actions)
          .id("\(setting.id)/\(row.machineId)")
      }
    }
  }
}
