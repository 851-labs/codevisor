import CodevisorCore
import SwiftUI

/// What a plugin row's menu can do. Everything that used to need a
/// per-machine page lives here, so the fleet list is the only plugin page.
public struct PluginFleetActions {
  public var update: (PluginFleetEntry) -> Void
  public var restore: (PluginFleetEntry) -> Void
  public var uninstall: (PluginFleetEntry) -> Void
  /// Removes a development link — the link, never the checkout behind it.
  public var unlink: (PluginFleetEntry, _ machineId: String) -> Void
  /// A menu item cannot own a sheet, so reporting is handed to the page.
  public var report: (PluginFleetEntry) -> Void
  /// Nil where there is no file browser to reveal into (iOS).
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

/// The shared plugin list: one row per plugin with the fleet's desired
/// toggle, then one quiet row per machine beneath it.
///
/// Plugins that cannot be shared — a linked development checkout, a
/// local-path install — sit in a short section under the machine they live
/// on, after the shared list. Grouping them by machine is what makes them
/// legible: the header answers "where is this", so the row only has to say
/// what kind of install it is, and nothing needs explaining in prose.
public struct PluginFleetSection<Footer: View>: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: PluginGlobalModel
  private let actions: PluginFleetActions
  private let footer: Footer

  /// - Parameter footer: the page's own actions (browse, install). They
  ///   belong to the shared list, not to whatever section happens to be
  ///   last — a machine's section is about that machine, and adding a
  ///   plugin has nothing to do with it.
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
    // One short section per machine that has plugins of its own. A machine
    // with nothing machine-bound contributes no section at all.
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

/// One fleet plugin: its row, then its machines. Reads the replica on every
/// render so the rows follow machines as they converge.
private struct PluginFleetRow: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry
  let machines: [FleetMachineInfo]
  let model: PluginGlobalModel
  let actions: PluginFleetActions

  var body: some View {
    let rows = PluginFleet.rows(pluginId: entry.id, sync: environment.configSync, machines: machines)
    // A plugin the fleet turned off has nothing to converge: just the name
    // and the toggle.
    let live = entry.setting?.enabled ?? false
    // Plugin machine rows carry no control — they only report. When every
    // machine agrees there is nothing to report, and a column of identical
    // green checks is the same noise a caption saying "available everywhere"
    // would be. Rows appear when the fleet disagrees with itself.
    let settled = rows.allSatisfy { $0.status == .ready }
    let showsMachines = live && machines.count > 1 && !settled
    // One machine is the fleet: its status folds into the plugin row.
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
      // Every plugin lists the same machines; rows need identity per pair
      // or the list reuses one plugin's rows for the next.
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

/// A plugin belonging to one machine, rendered inside that machine's
/// section. It lists no machines of its own: the section header already is
/// the machine, and there is no fleet state for it to differ from.
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

  /// The switch acts on the machine whose section this row sits in.
  private var toggle: Binding<Bool>? {
    let enabled = model.catalog[entry.id]?.isEnabled ?? true
    return Binding(
      get: { enabled },
      set: { next in Task { await setEnabled(machineId: machineId, enabled: next) } })
  }

  private func setEnabled(machineId: String, enabled: Bool) async {
    do {
      _ = try await environment.machines.client(for: machineId)
        .setPluginEnabled(pluginId: entry.id, enabled: enabled)
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
    }
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

/// Everything the old per-machine page offered, on the one row that owns the
/// plugin. Restart is per machine, so it becomes a submenu when more than
/// one machine is running it.
private struct PluginRowMenu: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: PluginFleetEntry
  let rows: [PluginFleet.MachineRow]
  let model: PluginGlobalModel
  let actions: PluginFleetActions
  /// Set when the row belongs to one machine's section.
  var unlinkMachineId: String?

  /// Plain text throughout. A row menu that mixes labelled items with a
  /// bare glyph reads as a mistake, and macOS list menus carry no icons
  /// anyway — the previous version inherited one from a button designed to
  /// sit in a row, not a menu.
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
      // Uninstalling would mean deleting the developer's checkout, which
      // Codevisor never does. Removing the link it created is the honest
      // action, and the wording has to say which one it is.
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
  /// The failure a machine row's mark opens, if it has one.
  func details(for row: PluginFleet.MachineRow) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .plugins, machineId: row.machineId, machineName: row.name,
      entryName: name, reason: reason)
  }
}
