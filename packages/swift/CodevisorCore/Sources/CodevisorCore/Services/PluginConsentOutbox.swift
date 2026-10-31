import Foundation

@MainActor
final class PluginConsentOutbox {
  struct Entry: Codable, Equatable {
    let id: String
    var account: String?
    let key: String
    let body: Data
  }

  struct Rejected: Error {}

  struct Outcome {
    var rejected: Set<String> = []
    var failures: [String: any Error] = [:]

    func throwFirstFailure() throws {
      if let failure = failures.values.first { throw failure }
    }
  }

  private enum Delivery {
    case delivered
    case rejected
    case failed(any Error)
  }

  private struct TokenScopedEntry: Decodable {
    let body: Data
  }

  private let store: any PersistenceStore
  private let storageKey = "pluginConsentOutbox"
  private var entries: [Entry]
  private var sending = false

  init(store: any PersistenceStore) {
    self.store = store
    entries = store.loadData(forKey: storageKey).map(Self.decodeEntries) ?? []
  }

  @discardableResult
  func record(key: String, account: String?, body: Data) throws -> String {
    let entry = Entry(id: UUID().uuidString, account: account, key: key, body: body)
    entries.removeAll { $0.account == account && $0.key == key }
    entries.append(entry)
    try persist()
    return entry.id
  }

  func flush(signedInAs account: String?, send: (Data) async throws -> Void) async throws -> Outcome {
    var outcome = Outcome()
    guard !sending else { return outcome }
    sending = true
    defer { sending = false }
    if let account { try adoptUnowned(by: account) }
    for entry in entries where entry.account == account {
      switch await delivery(of: entry, send: send) {
      case .delivered: break
      case .rejected: outcome.rejected.insert(entry.id)
      case let .failed(error):
        outcome.failures[entry.id] = error
        continue
      }
      try settle(entry)
    }
    return outcome
  }

  private func adoptUnowned(by account: String) throws {
    guard entries.contains(where: { $0.account == nil }) else { return }
    for index in entries.indices where entries[index].account == nil {
      entries[index].account = account
    }
    try persist()
  }

  private func delivery(of entry: Entry, send: (Data) async throws -> Void) async -> Delivery {
    do {
      try await send(PluginConsentRepair.repaired(entry.body))
      return .delivered
    } catch is Rejected {
      return .rejected
    } catch {
      return .failed(error)
    }
  }

  private func settle(_ entry: Entry) throws {
    entries.removeAll { $0 == entry }
    try persist()
  }

  private func persist() throws { try store.saveData(JSONEncoder().encode(entries), forKey: storageKey) }

  private static func decodeEntries(_ data: Data) -> [Entry] {
    let decoder = JSONDecoder()
    if let entries = try? decoder.decode([Entry].self, from: data) { return entries }
    guard let tokenScoped = try? decoder.decode([String: TokenScopedEntry].self, from: data) else { return [] }
    return tokenScoped.sorted { $0.key < $1.key }.map { id, entry in
      Entry(id: id, account: nil, key: String(id.drop { $0 != ":" }.dropFirst()), body: entry.body)
    }
  }
}
