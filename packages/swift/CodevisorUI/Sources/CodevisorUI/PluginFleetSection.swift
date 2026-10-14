import CodevisorCore
import SwiftUI

public struct PluginFleetActions {
  public var update: (PluginFleetEntry) -> Void
  public var restore: (PluginFleetEntry) -> Void
  public var uninstall: (PluginFleetEntry) -> Void
  public var unlink: (PluginFleetEntry, _ machineId: String) -> Void
  public var report: (PluginFleetEntry) -> Void
  public var reveal: ((_ path: String) -> Void)?

  public init(
    update: @escaping (PluginFleetEntry) -> Void,
    restore: @escaping (PluginFleetEntry) -> Void,
    uninstall: @escaping (PluginFleetEntry) -> Void,
    unlink: @escaping (PluginFleetEntry, _ machineId: String) -> Void,
    report: @escaping (PluginFleetEntry) -> Void,
    reveal: ((_ path: String) -> Void)? = nil
  ) {
    self.update = update
    self.restore = restore
    self.uninstall = uninstall
    self.unlink = unlink
    self.report = report
    self.reveal = reveal
  }
}

public struct PluginFleetSection<Footer: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: PluginGlobalModel
  private let actions: PluginFleetActions
  private let footer: Footer

  public init(
    model: PluginGlobalModel,
    actions: PluginFleetActions,
    @ViewBuilder footer: () -> Footer = { EmptyView() }
  ) {
    self.model = model
    self.actions = actions
    self.footer = footer()
  }

  public var body: some View {
    let machines = FleetMachineInfo.all(environment.machines)
    let entries = model.entries(environment.configSync)
    let fleet = entries.filter { !$0.isLocalOnly }
    let machineOnly = entries.filter(\.isLocalOnly)
    Section {
      if model.isLoading && entries.isEmpty {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else if entries.isEmpty {
        Text(model.loadFailed ? "No machine could report its plugins." : "No plugins installed yet.")
          .foregroundStyle(.secondary)
      } else if fleet.isEmpty {
        Text("No plugins yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(fleet) { entry in
          PluginFleetRow(entry: entry, machines: machines, model: model, actions: actions)
        }
      }
      if let actionError = model.actionError {
        Label(actionError, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
      }
    } footer: {
      footer
    }
    let hosts = machines.filter { machine in
      machineOnly.contains { entry in entry.localOnlyMachines.contains { $0.id == machine.id } }
    }
    ForEach(hosts) { machine in
      Section {
        ForEach(model.machineOnlyEntries(environment.configSync, machineId: machine.id)) { entry in
          PluginMachineOnlyRow(
            entry: entry, machineId: machine.id, machines: machines, model: model, actions: actions)
        }
      } header: {
        Text(machine.name)
      }
    }
  }
}

private struct PluginFleetRow: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry
  let machines: [FleetMachineInfo]
  let model: PluginGlobalModel
  let actions: PluginFleetActions

  var body: some View {
    let rows = PluginFleet.rows(pluginId: entry.id, sync: environment.configSync, machines: machines)
    let live = entry.setting?.enabled ?? false
    let settled = rows.allSatisfy { $0.status == .ready }
    let showsMachines = live && machines.count > 1 && !settled
    let single = live && machines.count == 1 ? rows.first : nil
    FleetEntryRow(
      name: entry.name,
      caption: caption,
      isBusy: single?.status.rowStatus.isBusy ?? false,
      isEnabled: Binding(
        get: { entry.setting?.enabled ?? false },
        set: { next in
          guard let setting = entry.setting else { return }
          PluginFleet.setEnabled(setting, enabled: next, in: environment.configSync)
        }),
      icon: { PluginRowIcon(entry: entry) },
      accessory: {
        if let single, single.status.rowStatus.isWorthFoldingUp {
          FleetStatusMark(status: single.status.rowStatus, details: entry.details(for: single))
        }
      },
      actions: {
        PluginRowMenu(entry: entry, rows: rows, model: model, actions: actions)
      })
    if showsMachines {
      ForEach(rows) { row in
        FleetMachineRow(
          name: row.name, status: row.status.rowStatus, details: entry.details(for: row)
        )
        .id("\(entry.id)/\(row.machineId)")
      }
    }
  }

  private var caption: String? {
    if let update = entry.updateAvailableVersion {
      return "\(entry.version ?? "Installed") · Update to \(update)"
    }
    return entry.version
  }
}

private struct PluginMachineOnlyRow: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry
  let machineId: String
  let machines: [FleetMachineInfo]
  let model: PluginGlobalModel
  let actions: PluginFleetActions

  var body: some View {
    let rows = PluginFleet.rows(pluginId: entry.id, sync: environment.configSync, machines: machines)
    let row = rows.first { $0.machineId == machineId }
    FleetEntryRow(
      name: entry.name,
      caption: caption,
      isBusy: row?.status.rowStatus.isBusy ?? false,
      isEnabled: toggle,
      icon: { PluginRowIcon(entry: entry) },
      accessory: {
        if let row, row.status.rowStatus.isWorthFoldingUp {
          FleetStatusMark(status: row.status.rowStatus, details: entry.details(for: row))
        }
      },
      actions: {
        PluginRowMenu(
          entry: entry, rows: rows, model: model, actions: actions, unlinkMachineId: machineId)
      })
  }

  private var caption: String {
    guard let version = entry.version else { return entry.localOnlyKind }
    return "\(entry.localOnlyKind) · \(version)"
  }

  private var toggle: Binding<Bool>? {
    Binding(
      get: { model.isEnabled(pluginId: entry.id, on: machineId) },
      set: { next in
        Task { await model.setEnabled(pluginId: entry.id, on: machineId, enabled: next, in: environment) }
      })
  }
}

private struct PluginRowIcon: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry

  var body: some View {
    if let machineId = entry.sourceMachineId {
      PluginIconView(
        pluginId: entry.id, iconPath: entry.iconPath,
        client: environment.machines.client(for: machineId),
        cacheNamespace: machineId, fallbackSystemName: "puzzlepiece")
    } else {
      Image(systemName: "puzzlepiece")
    }
  }
}

private struct PluginRowMenu: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry
  let rows: [PluginFleet.MachineRow]
  let model: PluginGlobalModel
  let actions: PluginFleetActions
  var unlinkMachineId: String?

  var body: some View {
    if entry.updateAvailableVersion != nil {
      Button("Update…") { actions.update(entry) }
    }
    if entry.canRestore {
      Button("Restore Previous Version…") { actions.restore(entry) }
    }
    restartControl
    if let reveal = actions.reveal, let path = entry.pathByMachine[CodevisorMachine.local.id] {
      Button("Reveal in Finder") { reveal(path) }
    }
    Button("Report Plugin…") { actions.report(entry) }
    Divider()
    if let machineId = unlinkMachineId {
      Button("Remove Link…", role: .destructive) { actions.unlink(entry, machineId) }
    } else {
      Button("Uninstall…", role: .destructive) { actions.uninstall(entry) }
    }
  }

  @ViewBuilder
  private var restartControl: some View {
    let running = rows.filter(\.status.isRunningHere)
    if running.count == 1, let only = running.first {
      Button("Restart") { Task { await restart(machineId: only.machineId) } }
    } else if running.count > 1 {
      Menu("Restart On") {
        ForEach(running) { row in
          Button(row.name) { Task { await restart(machineId: row.machineId) } }
        }
      }
    }
  }

  private func restart(machineId: String) async {
    do {
      _ = try await environment.machines.client(for: machineId).restartPlugin(pluginId: entry.id)
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}

public extension PluginFleetEntry {
  func details(for row: PluginFleet.MachineRow) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .plugins, machineId: row.machineId, machineName: row.name,
      entryName: name, reason: reason)
  }
}
