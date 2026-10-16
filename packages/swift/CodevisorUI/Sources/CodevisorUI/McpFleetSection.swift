import CodevisorCore
import SwiftUI

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

private struct McpFleetRow<MachineExtras: View, Icon: View>: View {
  @Environment(AppEnvironment.self) private var environment
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
    let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
    let rows = machineRows()
    let live = entry.isMachineScoped || entry.enabled || machines.count > 1
    let onlyMachine = machines.count == 1 ? rows.first : nil
    let showsMachines = machines.count > 1
    let single = live ? onlyMachine : nil
    let needsAuthorization =
      entry.authType == "oauth"
      && rows.contains { if case .needsAuthorization = $0.status { true } else { false } }
    FleetEntryRow(
      name: entry.name,
      caption: caption(rows: rows),
      isBusy: single?.status.rowStatus.isBusy ?? false,
      isEnabled: entryToggle(onlyMachine: onlyMachine),
      toggleDisabledReason: onlyMachine.flatMap { row in
        row.status.isOnHere ? nil : toggleDisabledReason(entry, row.machineId)
      },
      icon: { icon },
      accessory: {
        if live, needsAuthorization,
          let machineId = entry.machineId(preferring: CodevisorMachine.local.id)
        {
          Button("Connect…") { onConnect(entry, machineId) }
            .fleetRowButton()
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
      machineExtras(entry, only.machineId)
    }
  }

  private func entryToggle(onlyMachine: McpFleet.MachineRow?) -> Binding<Bool>? {
    guard machines.count <= 1 else { return nil }
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

struct McpMachineTrailing: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: McpFleetEntry
  let row: McpFleet.MachineRow
  let model: McpGlobalModel
  let disabledReason: String?

  var body: some View {
    #if os(macOS)
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

  private var availability: Binding<Bool> {
    Binding(
      get: { row.status.isOnHere && (entry.isMachineScoped || entry.enabled) },
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
        if next, !entry.enabled {
          for machine in FleetMachineInfo.all(environment.machines) where machine.id != row.machineId {
            guard let other = machine.syncKey else { continue }
            McpFleet.setDisabled(environment.configSync, machineId: other, name: entry.name, disabled: true)
          }
          McpFleet.setDisabled(environment.configSync, machineId: key, name: entry.name, disabled: false)
          Task { await model.setFleetEnabled(entry, enabled: true, in: environment) }
          return
        }
        McpFleet.setDisabled(
          environment.configSync, machineId: key, name: entry.name, disabled: !next)
      })
  }
}
