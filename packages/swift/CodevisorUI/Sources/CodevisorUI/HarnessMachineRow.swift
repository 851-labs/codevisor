import CodevisorCore
import SwiftUI

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

struct HarnessMachineActions {
  var signIn: ((_ machineId: String) -> Void)?
  var accounts: ((_ machineId: String) -> Void)?
}

struct HarnessMachineMark: View {
  let status: HarnessFleet.MachineStatus
  var details: FleetBlockedMachine?

  var body: some View {
    FleetStatusMark(status: status.rowStatus, details: details)
  }
}

struct HarnessMachineActionButton: View {
  @Environment(\.theme) private var theme
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions

  static func details(
    row: HarnessFleet.MachineRow, harnessName: String
  ) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .harnesses, machineId: row.machineId, machineName: row.name,
      entryName: harnessName, reason: reason)
  }

  var body: some View {
    Group {
      switch row.status {
      case .signInRequired, .signInFailed:
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
