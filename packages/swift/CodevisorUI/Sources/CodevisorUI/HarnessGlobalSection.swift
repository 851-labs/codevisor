import CodevisorCore
import SwiftUI

/// The shared harness list: one row per harness with the fleet's desired
/// toggle, then one quiet row per machine beneath it. Each app supplies its
/// harness icons and the sheets the callbacks present.
public struct HarnessGlobalSection<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: HarnessGlobalModel
  private let icon: (String, String) -> Icon
  private let onAccounts: (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void
  private let onSignIn: (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void

  /// - Parameters:
  ///   - onAccounts: presents the fleet-shared accounts sheet for a harness.
  ///   - onSignIn: presents machine-bound accounts / sign-in for one machine.
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
  /// The catalog rows, with the display name and symbol a machine reports
  /// for the harness taking precedence over what the row was authored with.
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

/// One harness across the fleet: its row, then its machines. Reads the
/// replica on every render so the rows follow machines as they converge.
private struct HarnessFleetRow<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
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
    // A disabled harness has nothing to converge: just the name and the toggle.
    let live = setting.enabled
    // One machine is the fleet: its action folds into the harness row.
    let single = live && machines.count == 1 ? status.machines.first : nil
    // Fleet-shared accounts belong to the harness row: its Sign In… /
    // Accounts… button is the one place to act, so machine rows under it
    // only report. Machine-bound harnesses act on the machine's row.
    let actions = HarnessMachineActions(
      signIn: sharesAccounts ? nil : { onSignIn($0, setting.id, true) },
      accounts: sharesAccounts || !shared.supportsAccounts ? nil : { onSignIn($0, setting.id, false) })
    // The Sign In… button says it; a caption would only repeat it.
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
      // The one thing to do about the fleet's accounts sits beside the
      // status, not behind the menu (which keeps the rare actions).
      if state.showsAccounts {
        Button("Accounts…") { onAccounts(setting, false) }
          .harnessRowButton(theme)
      }
      if let single {
        HarnessMachineActionButton(row: single, harnessName: setting.name, actions: actions)
        // One machine has nothing to converge with, so a check would only
        // restate the button beside it. Progress and failures still show:
        // the mark is where a failure explains itself.
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
      // Every harness lists the same machines; rows need identity per pair
      // or the list reuses one harness's rows for the next.
      ForEach(status.machines) { row in
        HarnessMachineRow(row: row, harnessName: setting.name, actions: actions)
          .id("\(setting.id)/\(row.machineId)")
      }
    }
  }
}
