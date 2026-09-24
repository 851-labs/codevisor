import Foundation

/// One-time move from the old storage, where the device kept its own editable
/// copies of workspaces, chats, and projects, to the navigation store.
///
/// Only what the device owns survives: the tab arrangement of every workspace
/// the server had confirmed. Everything else is dropped -- the server has the
/// real records, and the first sync after upgrading fetches them (showing a
/// spinner once per machine). Workspaces that only ever existed on this device
/// are dropped with the rest; the server never had them. That includes the
/// live duplicates earlier builds minted for chats whose workspace was
/// archived, which is what brought archived chats back into sidebars.
public enum NavigationStoreMigration {
  static let receiptKey = "navigation-store-migration-v1"
  static let legacyWorkspacesKey = "workspaces"
  /// The old workspace payload is kept, unread, for a release: an app rolled
  /// back to an older build, or an investigation into a user's state, still
  /// has what this device had before upgrading.
  static let legacyWorkspacesBackupKey = "workspaces-legacy-backup-v1"
  static let legacyKeys = [
    "workspaces", "projects", "sessions", "pending-server-sessions-v1", "pending-server-projects-v1",
    "pending-archived-sessions-v1",
  ]

  /// The fields of an old stored workspace this migration reads. Decoding
  /// only these keeps it independent of every other field the old format had.
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

  /// Decodes one element without failing the whole array.
  private struct FailableDecodable<Value: Decodable>: Decodable {
    var value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
  }

  /// Runs before the navigation store opens, so it sees the migrated layouts.
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
