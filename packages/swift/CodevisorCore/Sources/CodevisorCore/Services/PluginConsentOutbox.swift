import Foundation

@MainActor
final class PluginConsentOutbox {
  struct Entry: Codable, Equatable {
    let scope: String?
    let body: Data
  }

  private let store: any PersistenceStore
  private let storageKey = "pluginConsentOutbox"
  private var entries: [String: Entry]
  private var sending = false

  init(store: any PersistenceStore) {
    self.store = store
    entries =
      store.loadData(forKey: storageKey)
      .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
  }

  func record(key: String, scope: String?, body: Data) throws {
    entries["\(scope ?? "local"):\(key)"] = Entry(scope: scope, body: body)
    try persist()
  }

  func flush(scope: String?, send: (Data) async throws -> Void) async throws {
    guard let scope, !sending else { return }
    sending = true
    defer { sending = false }
    for (key, entry) in entries where entry.scope == scope {
      try await send(entry.body)
      if entries[key] == entry { entries.removeValue(forKey: key) }
      try persist()
    }
  }

  private func persist() throws { try store.saveData(JSONEncoder().encode(entries), forKey: storageKey) }
}
