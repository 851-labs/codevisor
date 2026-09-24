import CodevisorCore
import SwiftUI

/// One skill as the fleet list shows it: the replicated entry, plus the
/// description only a machine's scan carries.
public struct SkillFleetEntry: Identifiable, Equatable, Sendable {
  public var directoryName: String
  public var name: String
  /// The machine a never-published skill lives on; nil once it syncs.
  public var localOnlyMachineName: String?
  public var id: String { directoryName }
}

/// The shared skills list: one row per skill, then one quiet row per
/// machine. Skills have no enabled flag anywhere in the system, so the row
/// carries no toggle — a switch with nothing behind it would be a lie.
public struct SkillFleetSection: View {
  @Environment(AppEnvironment.self) private var environment
  private let model: SkillGlobalModel
  private let onEdit: (SkillFleetEntry) -> Void
  private let onRemove: (SkillFleetEntry) -> Void

  public init(
    model: SkillGlobalModel,
    onEdit: @escaping (SkillFleetEntry) -> Void,
    onRemove: @escaping (SkillFleetEntry) -> Void
  ) {
    self.model = model
    self.onEdit = onEdit
    self.onRemove = onRemove
  }

  public var body: some View {
    let machines = FleetMachineInfo.all(environment.machines)
    let entries = model.entries(environment.configSync)
    Section {
      if model.isLoading && entries.isEmpty {
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading…").foregroundStyle(.secondary)
        }
      } else if entries.isEmpty {
        Text(model.loadFailed ? "No machine could report its skills." : "No skills yet.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(entries) { entry in
          SkillFleetRow(
            entry: entry, machines: machines, model: model, onEdit: onEdit, onRemove: onRemove)
        }
      }
      if let actionError = model.actionError {
        Label(actionError, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }
}

/// One skill across the fleet: its row, then its machines.
private struct SkillFleetRow: View {
  @Environment(AppEnvironment.self) private var environment
  let entry: SkillFleetEntry
  let machines: [FleetMachineInfo]
  let model: SkillGlobalModel
  let onEdit: (SkillFleetEntry) -> Void
  let onRemove: (SkillFleetEntry) -> Void

  var body: some View {
    let rows = SkillFleet.rows(
      directoryName: entry.directoryName, sync: environment.configSync, machines: machines)
    // A skill every machine agrees on says so on its own row; only drift is
    // worth a list of machines.
    let settled = rows.allSatisfy { $0.status == .ready }
    let showsMachines = machines.count > 1 && !settled && entry.localOnlyMachineName == nil
    let single = machines.count == 1 ? rows.first : nil
    FleetEntryRow(
      name: entry.name,
      caption: caption,
      isBusy: single?.status.rowStatus.isBusy ?? false,
      icon: { Image(systemName: "book.closed") },
      accessory: {
        if let single {
          SkillMachineActionButton(entry: entry, row: single, model: model)
          if single.status.rowStatus.isWorthFoldingUp {
            FleetStatusMark(status: single.status.rowStatus, details: details(for: single))
          }
        }
      },
      actions: {
        Button("Edit…") { onEdit(entry) }
        Divider()
        Button("Remove…", role: .destructive) { onRemove(entry) }
      })
    if showsMachines {
      ForEach(rows) { row in
        FleetMachineRow(
          name: row.name, status: row.status.rowStatus, details: details(for: row)
        ) {
          SkillMachineActionButton(entry: entry, row: row, model: model)
        }
        .id("\(entry.directoryName)/\(row.machineId)")
      }
    }
  }

  /// Nothing under the name unless there is something unusual to say. The
  /// description used to sit here, but a paragraph of skill prose under
  /// every row turned the list into a wall of text — and the skill is one
  /// click away in the editor for anyone who wants to read it.
  private var caption: String? {
    entry.localOnlyMachineName.map { "Only on \($0)" }
  }

  private func details(for row: SkillFleet.MachineRow) -> FleetBlockedMachine? {
    guard let reason = row.status.rowStatus.reason else { return nil }
    return FleetBlockedMachine(
      plane: .skills, machineId: row.machineId, machineName: row.name,
      entryName: entry.name, reason: reason)
  }
}

/// A machine that has the skill but hasn't spread it into its harnesses can
/// be told to. Everything else is either fine, waiting on the ferry, or a
/// failure — and a failure explains itself from the row's mark.
private struct SkillMachineActionButton: View {
  @Environment(AppEnvironment.self) private var environment
  @Environment(\.theme) private var theme
  let entry: SkillFleetEntry
  let row: SkillFleet.MachineRow
  let model: SkillGlobalModel
  @State private var isSyncing = false

  var body: some View {
    Group {
      if row.status.canSync {
        Button(isSyncing ? "Syncing…" : "Sync") { Task { await sync() } }
          .disabled(isSyncing)
      }
    }
    .fleetRowButton(theme)
  }

  private func sync() async {
    isSyncing = true
    defer { isSyncing = false }
    do {
      _ = try await environment.machines.client(for: row.machineId)
        .syncSkills(directoryNames: [entry.directoryName])
      model.actionError = nil
      await model.load(in: environment)
    } catch {
      model.actionError = ErrorReporter.userFacingMessage(for: error)
    }
  }
}
