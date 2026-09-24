import CodevisorCore
import SwiftUI

/// The shared MCP list: one row per server, then one row per machine beneath
/// it. MCPs are the one plane with a real per-machine control, so a machine
/// row carries its own switch.
///
/// Managed servers have two levels: the server's toggle is the fleet's wish,
/// each machine's toggle is "available here". Built-ins have only the
/// machine level — they never replicate, so a fleet-wide switch over them
/// would be a control with nothing behind it. When the fleet is one machine
/// that lone switch folds up onto the server's row, so a single-machine user
/// still sees exactly one.
public struct McpFleetSection<MachineExtras: View, Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif
  private let model: McpGlobalModel
  private let builtIn: Bool
  private let onDetails: (McpFleetEntry) -> Void
  private let onEdit: (McpFleetEntry) -> Void
  private let onRemove: (McpFleetEntry) -> Void
  private let onConnect: (McpFleetEntry, _ machineId: String) -> Void
  private let toggleDisabledReason: (McpFleetEntry, _ machineId: String) -> String?
  private let icon: (McpFleetEntry) -> Icon
  private let machineExtras: (McpFleetEntry, _ machineId: String) -> MachineExtras

  /// - Parameters:
  ///   - builtIn: renders the built-in tools rather than managed servers.
  ///   - toggleDisabledReason: why one machine's switch cannot be turned on
  ///     — Computer Use needs permissions that machine hasn't granted.
  ///   - icon: the app supplies artwork it owns (the Codevisor mark lives in
  ///     each app's asset catalog, not in this package).
  ///   - machineExtras: content the host app puts under a machine row —
  ///     macOS uses it for the local Mac's Computer Use permission rows.
  public init(
    model: McpGlobalModel,
    builtIn: Bool,
    onDetails: @escaping (McpFleetEntry) -> Void,
    onEdit: @escaping (McpFleetEntry) -> Void,
    onRemove: @escaping (McpFleetEntry) -> Void,
    onConnect: @escaping (McpFleetEntry, _ machineId: String) -> Void,
    toggleDisabledReason: @escaping (McpFleetEntry, _ machineId: String) -> String? = { _, _ in
      nil
    },
    @ViewBuilder icon: @escaping (McpFleetEntry) -> Icon,
    @ViewBuilder machineExtras: @escaping (McpFleetEntry, _ machineId: String) -> MachineExtras
  ) {
    self.model = model
    self.builtIn = builtIn
    self.onDetails = onDetails
    self.onEdit = onEdit
    self.onRemove = onRemove
    self.onConnect = onConnect
    self.toggleDisabledReason = toggleDisabledReason
    self.icon = icon
    self.machineExtras = machineExtras
  }

  public var body: some View {
    let machines = FleetMachineInfo.all(environment.machines)
    let entries = builtIn ? model.builtIns : model.managed
    ForEach(entries) { entry in
      #if os(iOS)
        // A phone row holds a report and a disclosure; the controls live on
        // the pushed screen. iPad has the width to stay inline, like the Mac.
        if horizontalSizeClass == .compact, machines.count > 1 {
          let rows = McpGlobalModel.machineRows(
            entry: entry, sync: environment.configSync, machines: machines)
          NavigationLink {
            McpServerMachinesScreen(
              serverName: entry.name, model: model, onConnect: onConnect,
              onEdit: onEdit, onRemove: onRemove,
              toggleDisabledReason: toggleDisabledReason)
          } label: {
            McpCompactRow(entry: entry, rows: rows, icon: icon(entry))
          }
        } else {
          inlineRow(entry, machines: machines)
        }
      #else
        inlineRow(entry, machines: machines)
      #endif
    }
    if entries.isEmpty && !builtIn {
      Text(model.isLoading ? "Loading…" : "No MCP servers added yet.")
        .foregroundStyle(.secondary)
    }
  }

  private func inlineRow(_ entry: McpFleetEntry, machines: [FleetMachineInfo]) -> some View {
    McpFleetRow(
      entry: entry, machines: machines, model: model,
      onDetails: onDetails, onEdit: onEdit, onRemove: onRemove, onConnect: onConnect,
      toggleDisabledReason: toggleDisabledReason,
      icon: icon(entry),
      machineExtras: machineExtras)
  }
}

/// One server across the fleet: its row, then its machines.
private struct McpFleetRow<MachineExtras: View, Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let entry: McpFleetEntry
  let machines: [FleetMachineInfo]
  let model: McpGlobalModel
  let onDetails: (McpFleetEntry) -> Void
  let onEdit: (McpFleetEntry) -> Void
  let onRemove: (McpFleetEntry) -> Void
  let onConnect: (McpFleetEntry, _ machineId: String) -> Void
  let toggleDisabledReason: (McpFleetEntry, _ machineId: String) -> String?
  let icon: Icon
  @ViewBuilder let machineExtras: (McpFleetEntry, _ machineId: String) -> MachineExtras

  var body: some View {
    // Overlay flips must re-derive every row immediately, not on the next
    // report; reading the revision here is what subscribes this row to them.
    let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
    let rows = machineRows()
    // A built-in has no fleet wish, so its machines list whatever its state:
    // they are the only place it can be switched at all.
    let live = entry.isMachineScoped || entry.enabled
    let onlyMachine = machines.count == 1 ? rows.first : nil
    let showsMachines = live && machines.count > 1
    // One machine is the fleet: its status — and, for a built-in, its
    // switch — folds up onto the server's row.
    let single = live ? onlyMachine : nil
    // Authorizing is a fleet act: the material replicates, and every other
    // machine adopts it. So the button belongs on the server's row.
    let needsAuthorization =
      entry.authType == "oauth"
      && rows.contains { if case .needsAuthorization = $0.status { true } else { false } }
    FleetEntryRow(
      name: entry.name,
      caption: caption(rows: rows),
      isBusy: single?.status.rowStatus.isBusy ?? false,
      isEnabled: entryToggle(onlyMachine: onlyMachine),
      // Missing permissions block turning it ON; turning it off is always
      // allowed, so the reason only applies while the switch is off.
      toggleDisabledReason: onlyMachine.flatMap { row in
        row.status.isOnHere ? nil : toggleDisabledReason(entry, row.machineId)
      },
      icon: { icon },
      accessory: {
        if live, needsAuthorization,
          let machineId = entry.machineId(preferring: CodevisorMachine.local.id)
        {
          Button("Connect…") { onConnect(entry, machineId) }
            .fleetRowButton(theme)
        }
        if let single, single.status.rowStatus.isWorthFoldingUp {
          FleetStatusMark(status: single.status.rowStatus, details: details(for: single))
        }
      },
      actions: { menu })
    if showsMachines {
      ForEach(rows) { row in
        VStack(alignment: .leading, spacing: 0) {
          FleetMachineRow(
            name: row.name, status: row.status.rowStatus, details: details(for: row)
          ) {
            McpMachineTrailing(
              entry: entry, row: row, model: model,
              disabledReason: toggleDisabledReason(entry, row.machineId))
          }
          machineExtras(entry, row.machineId)
        }
        .id("\(entry.name)/\(row.machineId)")
      }
    } else if let only = rows.first, machines.count == 1 {
      // The rows under a built-in are its live dependency status and carry
      // the poll that notices a permission revoked in System Settings, so
      // they render whether or not the server is switched on.
      machineExtras(entry, only.machineId)
    }
  }

  /// The server row's switch. A managed server carries the fleet's wish. A
  /// built-in carries nothing unless the fleet is one machine, in which case
  /// it carries that machine's own switch rather than leaving the row inert
  /// and repeating itself one line below.
  private func entryToggle(onlyMachine: McpFleet.MachineRow?) -> Binding<Bool>? {
    guard entry.isMachineScoped else {
      return Binding(
        get: { entry.enabled },
        set: { next in
          Task { await model.setFleetEnabled(entry, enabled: next, in: environment) }
        })
    }
    guard let row = onlyMachine else { return nil }
    return Binding(
      get: { row.status.isOnHere },
      set: { next in
        Task {
          await model.setEnabled(entry, on: row.machineId, enabled: next, in: environment)
        }
      })
  }

  private func machineRows() -> [McpFleet.MachineRow] {
    McpGlobalModel.machineRows(entry: entry, sync: environment.configSync, machines: machines)
  }

  private func details(for row: McpFleet.MachineRow) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .mcps, machineId: row.machineId, machineName: row.name,
      entryName: entry.name, reason: reason)
  }

  /// The line under the name summarizes the fleet, not one machine: the tool
  /// count the machines agree on, or the spread when they don't.
  private func caption(rows: [McpFleet.MachineRow]) -> String? {
    guard entry.isMachineScoped || entry.enabled else { return nil }
    let counts = rows.compactMap { row -> Int? in
      if case .ready(let toolCount) = row.status { return toolCount }
      return nil
    }
    guard let first = counts.first else { return nil }
    if counts.allSatisfy({ $0 == first }) {
      return "\(first) tool\(first == 1 ? "" : "s")"
    }
    return "\(counts.min() ?? first)–\(counts.max() ?? first) tools across machines"
  }

  @ViewBuilder
  private var menu: some View {
    Button("Show Details…") { onDetails(entry) }
    if entry.canEdit {
      Button("Edit…") { onEdit(entry) }
    }
    if entry.canRemove {
      Divider()
      Button("Remove…", role: .destructive) { onRemove(entry) }
    }
  }
}

/// A machine row's controls: the per-machine switch, and the browser choice
/// for the one built-in that has one.
struct McpMachineTrailing: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: McpFleetEntry
  let row: McpFleet.MachineRow
  let model: McpGlobalModel
  let disabledReason: String?

  var body: some View {
    #if os(macOS)
      // A phone row cannot fit a machine name, a browser menu, a switch and
      // a mark — the name was truncating to "Dev Di…". The browser choice is
      // a machine-local setting and already Mac-only in spirit, like adding
      // and editing servers on this page.
      if entry.kind == "browserUse" {
        McpBrowserPicker(machineId: row.machineId, model: model)
      }
    #endif
    Toggle("Available on \(row.name)", isOn: availability)
      .labelsHidden().toggleStyle(.switch)
      .disabled(row.status == .unreachable || (!row.status.isOnHere && disabledReason != nil))
      .help(disabledReason ?? "")
      #if os(macOS)
        .controlSize(.mini)
      #endif
  }

  /// A built-in is switched on the machine itself — it never replicates, so
  /// there is no fleet definition for an overlay to override. A managed
  /// server's off writes this machine's overlay only; on clears it, and
  /// re-enables the fleet definition when that was what was off.
  private var availability: Binding<Bool> {
    Binding(
      get: { row.status.isOnHere },
      set: { next in
        if entry.isMachineScoped {
          Task {
            await model.setEnabled(
              entry, on: row.machineId, enabled: next, in: environment)
          }
          return
        }
        guard let key = environment.machines.syncKey(forMachineId: row.machineId) else {
          model.actionError = "\(row.name) hasn’t reported its identity yet."
          return
        }
        McpFleet.setDisabled(
          environment.configSync, machineId: key, name: entry.name, disabled: !next)
        if next, !entry.enabled {
          Task { await model.setFleetEnabled(entry, enabled: true, in: environment) }
        }
      })
  }
}
