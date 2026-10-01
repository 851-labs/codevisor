import Foundation
import Observation
import SwiftUI

/// SQLite-backed replacement for the app's direct `UserDefaults` usage.
///
/// The singleton is configured by `ClientStorageBootstrap` before either
/// platform constructs its view hierarchy. Reads intentionally touch
/// `revision`, allowing Swift Observation to invalidate a view that accesses a
/// value through `@ClientPreference`.
///
/// Reads and writes never touch SQLite on the main thread: a change lands in
/// the in-memory cache at once (so every later read sees it) and reaches the
/// database on the persistence queue, batched with the other changes made in
/// the meantime. `PersistenceEncoding.drain()` (and the app-lifecycle flushes
/// built on it) lands pending changes.
@MainActor
@Observable
public final class ClientPreferences {
  public static let shared = ClientPreferences()

  private var database: ClientDatabase?
  private var fallback: [String: Data] = [:]
  private var revision: UInt64 = 0
  /// Write-through cache of raw preference blobs, keyed by preference key.
  /// A stored `nil` records a confirmed-absent (or removed) key so misses
  /// don't re-query SQLite. All writes go through this class after
  /// `configure(database:)`, which resets the cache, so entries can never go
  /// stale. Ignored by Observation: views invalidate via `revision`, and
  /// populating the cache during a read must not mutate observed state.
  @ObservationIgnored private var cache: [String: Data?] = [:]
  /// The cache holds every preference (preloaded at launch, or cleared by
  /// `removeAll`), so a miss means absent without asking SQLite.
  @ObservationIgnored private var cacheIsComplete = false
  /// Changes not yet in `database`, applied in one transaction.
  @ObservationIgnored private var pendingWrites = PendingPreferenceWrites()
  @ObservationIgnored private let persistenceOwner = UUID()

  public init(database: ClientDatabase? = nil) {
    self.database = database
  }

  /// Attaches the database. `preferences`, when given, is every stored
  /// preference (read off the main thread by `openAsync`), which makes the
  /// cache complete: no read ever queries SQLite from the main thread.
  public func configure(database: ClientDatabase, preferences: [String: Data]? = nil) {
    self.database = database
    // Changes queued for a previous database still go to that one.
    pendingWrites = PendingPreferenceWrites()
    cache = preferences?.mapValues { Optional($0) } ?? [:]
    cacheIsComplete = preferences != nil
    revision &+= 1
  }

  public func value<Value: Codable>(
    forKey key: String,
    default defaultValue: Value
  ) -> Value {
    _ = revision
    guard let data = data(forKey: key),
      let decoded = try? JSONDecoder().decode(Value.self, from: data)
    else { return defaultValue }
    return decoded
  }

  public func valueIfPresent<Value: Codable>(
    forKey key: String,
    as type: Value.Type = Value.self
  ) -> Value? {
    _ = revision
    guard let data = data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(Value.self, from: data)
  }

  public func set<Value: Codable>(_ value: Value, forKey key: String) {
    do {
      let data = try JSONEncoder().encode(value)
      if database != nil {
        persist { $0.set(data, forKey: key) }
      } else {
        fallback[key] = data
      }
      cache[key] = data
      revision &+= 1
    } catch {
      Log.persistence.error(
        "Failed to save preference \(key, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func removeValue(forKey key: String) {
    if database != nil {
      persist { $0.set(nil, forKey: key) }
    } else {
      fallback[key] = nil
    }
    cache.updateValue(nil, forKey: key)
    revision &+= 1
  }

  public func removeAll() {
    if database != nil {
      persist { $0.clearAll() }
      // The rows are still in SQLite until the write lands; the cache is
      // now the whole truth, so a miss must not read them back.
      cacheIsComplete = true
    } else {
      fallback.removeAll()
    }
    cache.removeAll()
    revision &+= 1
  }

  /// Records a change and schedules the batch on the persistence queue.
  /// Coalesced: changes made before the batch runs share its transaction.
  private func persist(_ change: (PendingPreferenceWrites) -> Void) {
    guard let database else { return }
    let pending = pendingWrites
    change(pending)
    PersistenceEncoding.enqueueLatest(owner: persistenceOwner, key: pending.key) {
      let batch = pending.take()
      guard batch.clearsAll || !batch.changes.isEmpty else { return }
      do {
        try database.applyPreferenceChanges(clearingAll: batch.clearsAll, changes: batch.changes)
      } catch {
        Log.persistence.error(
          "Failed to save preferences: \(String(describing: error), privacy: .public)"
        )
      }
    }
  }

  private func data(forKey key: String) -> Data? {
    if let cached = cache[key] {
      return cached
    }
    let data: Data?
    if let database {
      // Only before a preload (the synchronous `open` path, tests).
      data = cacheIsComplete ? nil : try? database.preference(forKey: key)
    } else {
      data = fallback[key]
    }
    cache[key] = data
    return data
  }
}

/// Preference changes waiting for the persistence queue: the newest value
/// per key (nil: removed), and whether everything was cleared first. Shared
/// between the main actor, which records changes, and the queue, which
/// takes the batch.
private final class PendingPreferenceWrites: @unchecked Sendable {
  struct Batch {
    var clearsAll = false
    var changes: [String: Data?] = [:]
  }

  /// Distinguishes this batch's job from one for a previously configured
  /// database, so replacing the job can never drop the other's changes.
  let key = "client-preferences-\(UUID().uuidString)"
  private let lock = NSLock()
  private var batch = Batch()

  func set(_ data: Data?, forKey key: String) {
    lock.withLock { batch.changes[key] = .some(data) }
  }

  func clearAll() {
    lock.withLock { batch = Batch(clearsAll: true) }
  }

  func take() -> Batch {
    lock.withLock {
      defer { batch = Batch() }
      return batch
    }
  }
}

/// SwiftUI-friendly typed preference backed by `ClientPreferences`.
///
/// This deliberately mirrors the small surface the app used from
/// `@AppStorage`: direct value reads/writes and a projected `Binding`.
@MainActor
@propertyWrapper
public struct ClientPreference<Value: Codable & Equatable> {
  private let key: String
  private let defaultValue: Value

  public init(_ key: String, default defaultValue: Value) {
    self.key = key
    self.defaultValue = defaultValue
  }

  public var wrappedValue: Value {
    get {
      ClientPreferences.shared.value(forKey: key, default: defaultValue)
    }
    nonmutating set {
      ClientPreferences.shared.set(newValue, forKey: key)
    }
  }

  public var projectedValue: Binding<Value> {
    Binding(
      get: { wrappedValue },
      set: { wrappedValue = $0 }
    )
  }
}
