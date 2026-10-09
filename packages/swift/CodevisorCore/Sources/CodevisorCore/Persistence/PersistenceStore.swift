import Foundation

/// A simple key-addressable byte store, abstracted so repositories can be
/// tested in memory without touching the file system.
public protocol PersistenceStore: Sendable {
  func loadData(forKey key: String) -> Data?
  func saveData(_ data: Data, forKey key: String) throws
  func removeData(forKey key: String) throws
  /// Moves the persisted payload for `key` aside after a decode failure so
  /// the next save doesn't overwrite the evidence. Stores without durable
  /// files can rely on the default no-op.
  func quarantineCorruptData(forKey key: String)
}

extension PersistenceStore {
  public func quarantineCorruptData(forKey key: String) {}
}

/// Shared handling for a persisted payload that failed to decode: quarantines
/// the durable bytes (keeping a backup instead of letting the next save
/// overwrite them), logs a fault, and optionally surfaces a banner. Empty
/// payloads are logged but not quarantined — there is nothing to back up.
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

/// An in-memory `PersistenceStore` for tests and previews.
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
