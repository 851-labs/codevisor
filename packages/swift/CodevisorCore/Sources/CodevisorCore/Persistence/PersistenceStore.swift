import Foundation

public protocol PersistenceStore: Sendable {
  func loadData(forKey key: String) -> Data?
  func saveData(_ data: Data, forKey key: String) throws
  func removeData(forKey key: String) throws
  func quarantineCorruptData(forKey key: String)
}

extension PersistenceStore {
  public func quarantineCorruptData(forKey key: String) {}
}

func handleCorruptPayload(
  store: any PersistenceStore,
  key: String,
  data: Data,
  error: any Error,
  reportTitle: String? = nil,
  reportMessage: String? = nil
) {
  guard !data.isEmpty else {
    Log.persistence.error(
      "Empty persisted payload for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
    return
  }
  store.quarantineCorruptData(forKey: key)
  Log.persistence.fault(
    "Corrupt persisted payload for \(key, privacy: .public); kept a backup: \(String(describing: error), privacy: .public)"
  )
  guard let reportTitle else { return }
  Task { @MainActor in
    ErrorReporter.shared.report(
      .corruptPersistedData,
      title: reportTitle,
      message: reportMessage
    )
  }
}

public final class InMemoryStore: PersistenceStore, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Data]

  public init(storage: [String: Data] = [:]) {
    self.storage = storage
  }

  public func loadData(forKey key: String) -> Data? {
    lock.withLock { storage[key] }
  }

  public func saveData(_ data: Data, forKey key: String) throws {
    lock.withLock { storage[key] = data }
  }

  public func removeData(forKey key: String) throws {
    lock.withLock { storage[key] = nil }
  }
}
