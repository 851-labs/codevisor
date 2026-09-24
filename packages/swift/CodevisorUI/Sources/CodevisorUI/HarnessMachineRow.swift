import CodevisorCore
import SwiftUI

/// One machine under a harness. The chrome is `FleetMachineRow`, shared with
/// the MCP, skills, and plugin pages; only the action a harness offers is
/// specific to this plane. A failure opens from the row's mark, not from a
/// button of its own.
struct HarnessMachineRow: View {
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions

  var body: some View {
    FleetMachineRow(
      name: row.name,
      status: row.status.rowStatus,
      details: HarnessMachineActionButton.details(row: row, harnessName: harnessName)
    ) {
      HarnessMachineActionButton(row: row, harnessName: harnessName, actions: actions)
    }
  }
}

/// What a machine row can do, supplied by the harness it belongs to.
struct HarnessMachineActions {
  /// Signs this machine in, or the whole fleet for a fleet-shared harness.
  var signIn: ((_ machineId: String) -> Void)?
  /// Nil when accounts are fleet-shared or the harness needs none.
  var accounts: ((_ machineId: String) -> Void)?
}

/// A check once a machine is in sync; a spinner while it catches up; a mark
/// when it needs the user. Kept as a harness-shaped alias over the shared
/// mark so the harness row's accessory slot reads the same as before.
struct HarnessMachineMark: View {
  let status: HarnessFleet.MachineStatus
  var details: FleetBlockedMachine?

  var body: some View {
    FleetStatusMark(status: status.rowStatus, details: details)
  }
}

/// The one action a machine's status calls for, as a plain button: a menu
/// with a single item hid it behind a click. Nothing renders while the
/// machine is converging, has nothing to offer, or only needs explaining —
/// that last case belongs to the mark. The same button sits in the harness
/// row when the fleet is one machine.
struct HarnessMachineActionButton: View {
  @Environment(\.theme) private var theme
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions

  /// The failure this row's mark opens, if it has one.
  static func details(
    row: HarnessFleet.MachineRow, harnessName: String
  ) -> FleetBlockedMachine? {
    guard case .blocked(let reason) = row.status else { return nil }
    return FleetBlockedMachine(
      plane: .harnesses, machineId: row.machineId, machineName: row.name,
      entryName: harnessName, reason: reason)
  }

  var body: some View {
    Group {
      switch row.status {
      case .signInRequired:
        if let signIn = actions.signIn {
          Button("Sign In…") { signIn(row.machineId) }
        }
      case .ready:
        if let accounts = actions.accounts {
          Button("Accounts…") { accounts(row.machineId) }
        }
      default:
        EmptyView()
      }
    }
    .fleetRowButton(theme)
  }
}
