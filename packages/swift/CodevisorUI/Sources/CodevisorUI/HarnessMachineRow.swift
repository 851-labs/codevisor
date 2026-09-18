import CodevisorCore
import SwiftUI

/// One machine under a harness: its name, a mark only when something is
/// wrong, and a menu. The mark's tooltip says what; the menu says what to do.
struct HarnessMachineRow: View {
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions

  var body: some View {
    HStack(spacing: 10) {
      Text(row.name)
      Spacer(minLength: 8)
      HarnessMachineMark(status: row.status)
      HarnessMachineMenu(row: row, harnessName: harnessName, actions: actions)
    }
    .padding(.vertical, 2)
    #if os(macOS)
      .padding(.leading, 32)
    #else
      .padding(.leading, 20)
    #endif
  }
}

/// What a machine row can do, supplied by the harness it belongs to.
struct HarnessMachineActions {
  /// Nil when the harness signs in once for the whole fleet.
  var signIn: ((_ machineId: String) -> Void)?
  /// Nil when accounts are fleet-shared or the harness needs none.
  var accounts: ((_ machineId: String) -> Void)?
}

/// A check once a machine is in sync; a spinner while it catches up with
/// the fleet; a mark when it needs the user. Hover explains any of them.
struct HarnessMachineMark: View {
  @Environment(\.theme) private var theme
  let status: HarnessFleet.MachineStatus

  var body: some View {
    if status == .ready {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(theme.statusOK)
        .help(status.label)
        .accessibilityLabel(status.label)
    } else if status.isBusy {
      ProgressView().controlSize(.small)
        .help(status.label)
    } else if status.needsAttention {
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(theme.statusWarn)
        .help(status.label)
        .accessibilityLabel(status.label)
    }
  }
}

/// A machine's own menu: the status in words, then what to do about it.
struct HarnessMachineMenu: View {
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions
  @State private var blocked: HarnessBlockedMachine?

  var body: some View {
    Menu {
      HarnessMachineMenuItems(row: row, harnessName: harnessName, actions: actions, blocked: $blocked)
    } label: {
      Label("\(row.name) options", systemImage: "ellipsis.circle")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    #if os(macOS)
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    #endif
    .harnessBlockedDetails(item: $blocked)
  }
}

/// The same items also sit in the harness row's menu when the fleet is one
/// machine; the presenter then belongs to whoever owns `blocked`.
struct HarnessMachineMenuItems: View {
  @Environment(AppEnvironment.self) private var environment
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions
  @Binding var blocked: HarnessBlockedMachine?

  var body: some View {
    Button(row.status.label) {}.disabled(true)
    switch row.status {
    case .signInRequired:
      if let signIn = actions.signIn {
        Button("Sign In…", systemImage: "person.crop.circle.badge.plus") { signIn(row.machineId) }
      }
    case .ready:
      if let accounts = actions.accounts {
        Button("Accounts…", systemImage: "person.crop.circle") { accounts(row.machineId) }
      }
    case .blocked(let reason):
      Button("Details…", systemImage: "info.circle") {
        blocked = .init(machineId: row.machineId, machineName: row.name, harnessName: harnessName, reason: reason)
      }
      Button("Retry", systemImage: "arrow.clockwise") {
        Task {
          _ = try? await environment.machines.client(for: row.machineId).reconcileHarnessesSync()
          environment.harnessCatalogDidChange(onServer: row.machineId)
        }
      }
    default:
      EmptyView()
    }
    Divider()
  }
}
