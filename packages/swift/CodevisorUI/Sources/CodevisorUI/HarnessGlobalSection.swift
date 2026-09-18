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
  private let onEditCustom: ((HarnessFleet.Setting) -> Void)?

  /// - Parameters:
  ///   - onAccounts: presents the fleet-shared accounts sheet for a harness.
  ///   - onSignIn: presents machine-bound accounts / sign-in for one machine.
  ///   - onEditCustom: edits a custom harness definition; nil hides Edit….
  public init(
    model: HarnessGlobalModel,
    onAccounts: @escaping (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void,
    onSignIn: @escaping (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void,
    onEditCustom: ((HarnessFleet.Setting) -> Void)? = nil,
    @ViewBuilder icon: @escaping (String, String) -> Icon
  ) {
    self.model = model
    self.onAccounts = onAccounts
    self.onSignIn = onSignIn
    self.onEditCustom = onEditCustom
    self.icon = icon
  }

  private var settings: [HarnessFleet.Setting] {
    HarnessFleet.settings(environment.configSync).map { setting in
      guard let harness = model.catalog.first(where: { $0.id == setting.id }) else { return setting }
      var result = setting
      result.name = harness.name
      result.symbolName = harness.symbolName
      return result
    }
  }

  public var body: some View {
    let machines = HarnessFleet.fleetMachines(environment.machines)
    Section {
      ForEach(settings) { setting in
        HarnessFleetRow(
          setting: setting, machines: machines, model: model,
          onAccounts: onAccounts, onSignIn: onSignIn, onEditCustom: onEditCustom
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

/// One harness across the fleet: its row, then its machines. Reads the
/// replica on every render so the rows follow machines as they converge.
private struct HarnessFleetRow<Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  let setting: HarnessFleet.Setting
  let machines: [HarnessFleet.FleetMachine]
  let model: HarnessGlobalModel
  let onAccounts: (HarnessFleet.Setting, _ startsSignIn: Bool) -> Void
  let onSignIn: (_ machineId: String, _ harnessId: String, _ startsSignIn: Bool) -> Void
  let onEditCustom: ((HarnessFleet.Setting) -> Void)?
  @ViewBuilder let icon: () -> Icon
  @State private var blocked: HarnessBlockedMachine?

  var body: some View {
    let sharesAccounts = HarnessRowState.sharesFleetAccounts(harnessId: setting.id)
    let shared = HarnessRowState.shared(
      harnessId: setting.id, sync: environment.configSync,
      authRequired: model.catalog.first(where: { $0.id == setting.id })?.auth?.resolvedState != .notRequired)
    let status = HarnessFleet.status(
      harnessId: setting.id, sync: environment.configSync, machines: machines,
      sharesAccounts: sharesAccounts, sharedSignInPending: shared.needsSignIn)
    // A disabled harness has nothing to converge: just the name and the toggle.
    let live = setting.enabled
    // One machine is the fleet: its mark and menu fold into the harness row.
    let single = live && machines.count == 1 ? status.machines.first : nil
    let actions = HarnessMachineActions(
      signIn: sharesAccounts ? nil : { onSignIn($0, setting.id, true) },
      accounts: sharesAccounts || !shared.supportsAccounts ? nil : { onSignIn($0, setting.id, false) })
    let state = HarnessRowState(
      status: live && sharesAccounts && shared.needsSignIn ? "Sign in required" : nil,
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
      if let single {
        HarnessMachineMark(status: single.status)
      }
    } actions: {
      if state.showsAccounts {
        Button("Accounts…", systemImage: "person.crop.circle") { onAccounts(setting, false) }
      }
      if let single {
        HarnessMachineMenuItems(row: single, harnessName: setting.name, actions: actions, blocked: $blocked)
      }
      if let onEditCustom, model.customSpecs[setting.id] != nil {
        Button("Edit…", systemImage: "pencil") { onEditCustom(setting) }
      }
      Button("Uninstall…", role: .destructive) { model.uninstall = setting }
    }
    .harnessBlockedDetails(item: $blocked)
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
