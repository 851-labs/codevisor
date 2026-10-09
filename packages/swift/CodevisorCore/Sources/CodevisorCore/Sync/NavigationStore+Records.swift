import Foundation

/// The account-wide sidebar records -- folders, the grouping mode, project
/// order -- have no home machine, so this device writes each one to every
/// machine it knows and fills in machines that are missing a newer copy.
/// Every machine keeps the newest revision of a record, so all of them, and
/// every device reading them, converge on the same last write.
extension NavigationStore {
  /// The setting that picks how the sidebar groups agents.
  public static let sidebarGroupingKey = "sidebar.grouping"

  /// The prefix of each project's place in the sidebar's project order.
  public static let projectOrderKeyPrefix = "project.order."

  public var navigationRecords: ServerNavigationRecords { projection.navigationRecords }

  /// The live (not deleted) folders, in sidebar order.
  public var folders: [ServerNavigationFolder] {
    projection.navigationRecords.folders.filter { !$0.deleted }.sorted { lhs, rhs in
      lhs.position == rhs.position ? lhs.id < rhs.id : lhs.position < rhs.position
    }
  }

  public func setting(_ key: String) -> String? {
    projection.navigationRecords.settings.first { $0.key == key }?.value
  }

  /// Creates or changes a folder on every machine.
  public func saveFolder(id: UUID, name: String, position: String, collapsed: Bool = false) {
    let folder = ServerNavigationFolder(
      id: id.uuidString.lowercased(), name: name, position: position, collapsed: collapsed,
      revision: recordClock.next())
    enqueueEverywhere(.putNavigationFolder(folder))
  }

  /// Deletes a folder on every machine, leaving a tombstone.
  public func deleteFolder(id: UUID) {
    guard var folder = projection.navigationRecords.folders.first(where: { UUID(uuidString: $0.id) == id })
    else { return }
    folder.deleted = true
    folder.revision = recordClock.next()
    enqueueEverywhere(.putNavigationFolder(folder))
  }

  /// Changes a navigation setting on every machine.
  public func setSetting(_ key: String, value: String) {
    enqueueEverywhere(
      .putNavigationSetting(ServerNavigationSetting(key: key, value: value, revision: recordClock.next())))
  }

  private func enqueueEverywhere(_ intent: NavigationIntent) {
    let machineIds = cachedMachineIds.sorted()
    for machineId in machineIds {
      enqueueWithoutRebuild(intent, machineId: machineId)
    }
    rebuild()
    for machineId in machineIds { executor.resume(machineId: machineId) }
  }

  /// Sends each machine the records it is missing or holds an older copy
  /// of. A record goes to a machine at most once per revision in a session,
  /// so a machine that can't take it (an older server) is not retried in a
  /// loop.
  func replicateNavigationRecords() {
    let merged = projection.navigationRecords
    for record in merged.folders { recordClock.witness(record.revision) }
    for record in merged.settings { recordClock.witness(record.revision) }
    var resumed = Set<String>()
    for machineId in cachedMachineIds.sorted() {
      let held = projection.machineRecords[machineId] ?? ServerNavigationRecords()
      for folder in merged.folders {
        let current = held.folders.first { $0.id.lowercased() == folder.id.lowercased() }
        guard current.map({ $0.revision < folder.revision }) ?? true,
          replicated.insert("\(machineId)|folder|\(folder.id.lowercased())|\(folder.revision)").inserted
        else { continue }
        enqueueWithoutRebuild(.putNavigationFolder(folder), machineId: machineId)
        resumed.insert(machineId)
      }
      for setting in merged.settings {
        let current = held.settings.first { $0.key == setting.key }
        guard current.map({ $0.revision < setting.revision }) ?? true,
          replicated.insert("\(machineId)|setting|\(setting.key)|\(setting.revision)").inserted
        else { continue }
        enqueueWithoutRebuild(.putNavigationSetting(setting), machineId: machineId)
        resumed.insert(machineId)
      }
    }
    guard !resumed.isEmpty else { return }
    rebuild()
    for machineId in resumed { executor.resume(machineId: machineId) }
  }
}
