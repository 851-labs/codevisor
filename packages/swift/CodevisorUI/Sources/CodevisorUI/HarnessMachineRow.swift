import CodevisorCore
import SwiftUI

/// One machine under a harness: its name, then — when there is exactly one
/// thing to do about its status — that action as a button, and a mark only
/// when something is wrong. Marks trail so they line up down the list
/// whether or not a row has a button; the mark's tooltip says what.
struct HarnessMachineRow: View {
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions

  var body: some View {
    HStack(spacing: 10) {
      Text(row.name)
        .lineLimit(1)
        .layoutPriority(1)
      Spacer(minLength: 8)
      HarnessMachineActionButton(row: row, harnessName: harnessName, actions: actions)
      #if os(macOS)
        HarnessMachineMark(status: row.status)
          .frame(width: HarnessSettingsRow<EmptyView, EmptyView, EmptyView>.trailingControlWidth)
      #else
        HarnessMachineMark(status: row.status)
      #endif
    }
    .frame(minHeight: HarnessSettingsRow<EmptyView, EmptyView, EmptyView>.minContentHeight)
    .padding(.vertical, 4)
    .padding(.leading, HarnessSettingsRow<EmptyView, EmptyView, EmptyView>.iconColumnWidth)
  }
}

/// What a machine row can do, supplied by the harness it belongs to.
struct HarnessMachineActions {
  /// Signs this machine in, or the whole fleet for a fleet-shared harness.
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

/// The one action a machine's status calls for, as a plain button: a menu
/// with a single item hid it behind a click. Nothing renders while the
/// machine is converging or has nothing to offer. The same button sits in
/// the harness row when the fleet is one machine.
struct HarnessMachineActionButton: View {
  @Environment(\.theme) private var theme
  let row: HarnessFleet.MachineRow
  let harnessName: String
  let actions: HarnessMachineActions
  @State private var blocked: HarnessBlockedMachine?

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
      case .blocked(let reason):
        // The popover carries the reason and the retry.
        Button("Details…") {
          blocked = .init(machineId: row.machineId, machineName: row.name, harnessName: harnessName, reason: reason)
        }
      default:
        EmptyView()
      }
    }
    .harnessRowButton(theme)
    .harnessBlockedDetails(item: $blocked)
  }
}
