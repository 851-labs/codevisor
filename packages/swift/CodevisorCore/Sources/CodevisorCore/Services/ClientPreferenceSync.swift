import ACPKit
import Foundation

@MainActor
final class ClientPreferenceSync {
  static let namespace = "client-preferences"
  static let unmergedListsKey = "clientPreferenceSync.unmergedLists"

  private let preferences: ClientPreferences
  private let configSync: ConfigSync
  private let keys: Set<String>
  private var unmergedLists: [String: [JSONValue]]

  init(preferences: ClientPreferences, configSync: ConfigSync, keys: Set<String>) {
    self.preferences = preferences
    self.configSync = configSync
    self.keys = keys
    unmergedLists = preferences.value(forKey: Self.unmergedListsKey, default: [:])
  }

  func start() {
    if preferences.data(forKey: Self.unmergedListsKey) == nil { publishValuesFromBeforeSync() }
    adoptSyncedValues()
    preferences.onLocalChange = { [weak self] in self?.publish($0) }
  }

  func adoptSyncedValues() {
    var merged: [String: JSONValue] = [:]
    let unmergedCount = unmergedLists.count
    for entry in configSync.entries(namespace: Self.namespace) where keys.contains(entry.key) {
      var synced: JSONValue? = entry.deleted == true ? nil : entry.value
      if entry.timestamp.deviceId != configSync.deviceId,
        let local = unmergedLists.removeValue(forKey: entry.key)
      {
        let union = Self.union(synced, local)
        if union != synced, let union { merged[entry.key] = union }
        synced = union
      }
      guard synced != localValue(forKey: entry.key) else { continue }
      preferences.store(synced.flatMap { try? JSONEncoder().encode($0) }, forKey: entry.key)
    }
    if unmergedLists.count != unmergedCount { saveUnmergedLists() }
    for (key, value) in merged.sorted(by: { $0.key < $1.key }) {
      configSync.set(namespace: Self.namespace, key: key, value: value)
    }
  }

  private func publishValuesFromBeforeSync() {
    let synced = Set(configSync.entries(namespace: Self.namespace).map(\.key))
    let olderThanAnyWrite = ServerSyncTimestamp(wallMs: 0, counter: 0, deviceId: configSync.deviceId)
    var entries: [ServerSyncEntry] = []
    for key in keys.sorted() {
      guard let value = localValue(forKey: key) else { continue }
      if case .array(let items) = value { unmergedLists[key] = items }
      if !synced.contains(key) {
        entries.append(ServerSyncEntry(key: key, value: value, timestamp: olderThanAnyWrite))
      }
    }
    saveUnmergedLists()
    configSync.applyRemoteChange(namespace: Self.namespace, entries: entries)
  }

  private func publish(_ change: LocalPreferenceChange) {
    guard keys.contains(change.key) else { return }
    let synced = configSync.value(namespace: Self.namespace, key: change.key)
    if let synced, let data = try? JSONEncoder().encode(synced), !change.canDecode(data) { return }
    if unmergedLists.removeValue(forKey: change.key) != nil { saveUnmergedLists() }
    guard let data = change.data else {
      if synced != nil { configSync.remove(namespace: Self.namespace, key: change.key) }
      return
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), value != synced else { return }
    configSync.set(namespace: Self.namespace, key: change.key, value: value)
  }

  private func localValue(forKey key: String) -> JSONValue? {
    preferences.data(forKey: key).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
  }

  private func saveUnmergedLists() {
    preferences.store(try? JSONEncoder().encode(unmergedLists), forKey: Self.unmergedListsKey)
  }

  private static func union(_ synced: JSONValue?, _ local: [JSONValue]) -> JSONValue? {
    switch synced {
    case .array(let items)?: .array(items + local.filter { !items.contains($0) })
    case nil: .array(local)
    case let other?: other
    }
  }
}
