import Foundation

@MainActor
final class PluginConsentOutbox {
  struct Entry: Codable, Equatable {
    let scope: String?
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

  @discardableResult
  func record(key: String, scope: String?, body: Data) throws -> String {
    let id = "\(scope ?? "local"):\(key)"
    entries[id] = Entry(scope: scope, body: body)
    try persist()
    return id
  }

  func flush(scope: String?, send: (Data) async throws -> Void) async throws -> Outcome {
    var outcome = Outcome()
    guard let scope, !sending else { return outcome }
    sending = true
    defer { sending = false }
    for (id, entry) in entries where entry.scope == scope {
      switch await delivery(of: entry, send: send) {
      case .delivered: break
      case .rejected: outcome.rejected.insert(id)
      case let .failed(error):
        outcome.failures[id] = error
        continue
      }
      try settle(id, entry)
    }
    return outcome
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

  private func settle(_ id: String, _ entry: Entry) throws {
    if entries[id] == entry { entries.removeValue(forKey: id) }
    try persist()
  }

  private func persist() throws { try store.saveData(JSONEncoder().encode(entries), forKey: storageKey) }
}
