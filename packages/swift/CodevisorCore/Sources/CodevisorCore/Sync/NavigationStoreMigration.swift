import Foundation

public enum NavigationStoreMigration {
  static let receiptKey = "navigation-store-migration-v1"
  static let legacyWorkspacesKey = "workspaces"
  static let legacyWorkspacesBackupKey = "workspaces-legacy-backup-v1"
  static let legacyKeys = [
    "workspaces", "projects", "sessions", "pending-server-sessions-v1", "pending-server-projects-v1",
    "pending-archived-sessions-v1",
  ]

  private struct LegacyWorkspace: Decodable {
    var id: UUID
    var serverId: String
    var isServerSynced: Bool?
    var centerTabs: [WorkspaceTab]?
    var selectedCenterTabId: UUID?
  }

  private struct LegacyPayload: Decodable {
    var workspaces: [FailableDecodable<LegacyWorkspace>]
  }

  private struct FailableDecodable<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
  }

  public static func runIfNeeded(store: any PersistenceStore, machineIds: [String]) {
    guard store.loadData(forKey: receiptKey) == nil else { return }
    PersistenceEncoding.drain()
    let layouts = DeviceLayoutStore(store: store)
    if let data = store.loadData(forKey: legacyWorkspacesKey),
      let payload = try? JSONDecoder().decode(LegacyPayload.self, from: data)
    {
      for case let legacy? in payload.workspaces.map(\.value) where legacy.isServerSynced == true {
        guard let tabs = legacy.centerTabs, let first = tabs.first else { continue }
        let selected = legacy.selectedCenterTabId.flatMap { id in tabs.contains { $0.id == id } ? id : nil }
        layouts.setLayout(
          DeviceLayout(serverId: legacy.serverId, tabs: tabs, selectedTabId: selected ?? first.id), for: legacy.id)
      }
    }
    PersistenceEncoding.drain()
    if let data = store.loadData(forKey: legacyWorkspacesKey) {
      try? store.saveData(data, forKey: legacyWorkspacesBackupKey)
    }
    for key in legacyKeys { try? store.removeData(forKey: key) }
    for machineId in machineIds {
      let safe = machineId.map { $0.isLetter || $0.isNumber ? $0 : "-" }
      try? store.removeData(forKey: "server-authority-v1-\(String(safe))")
    }
    try? store.saveData(Data("1".utf8), forKey: receiptKey)
  }
}
