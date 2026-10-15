import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
public final class ClientPreferences {
  public static let shared = ClientPreferences()

  private var database: ClientDatabase?
  private var fallback: [String: Data] = [:]
  private var revision: UInt64 = 0
  @ObservationIgnored private var cache: [String: Data?] = [:]
  @ObservationIgnored private var cacheIsComplete = false
  @ObservationIgnored private var pendingWrites = PendingPreferenceWrites()
  @ObservationIgnored private let persistenceOwner = UUID()
  @ObservationIgnored var onLocalChange: ((LocalPreferenceChange) -> Void)?

  public init(database: ClientDatabase? = nil) {
    self.database = database
  }

  public func configure(database: ClientDatabase, preferences: [String: Data]? = nil) {
    self.database = database
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
      store(data, forKey: key)
      onLocalChange?(
        LocalPreferenceChange(key: key, data: data) { (try? JSONDecoder().decode(Value.self, from: $0)) != nil }
      )
    } catch {
      Log.persistence.error(
        "Failed to save preference \(key, privacy: .public): \(String(describing: error), privacy: .public)"
      )
    }
  }

  public func removeValue(forKey key: String) {
    store(nil, forKey: key)
    onLocalChange?(LocalPreferenceChange(key: key, data: nil) { _ in true })
  }

  public func removeAll() {
    if database != nil {
      persist { $0.clearAll() }
      cacheIsComplete = true
    } else {
      fallback.removeAll()
    }
    cache.removeAll()
    revision &+= 1
  }

  func store(_ data: Data?, forKey key: String) {
    if database != nil {
      persist { $0.set(data, forKey: key) }
    } else {
      fallback[key] = data
    }
    cache.updateValue(data, forKey: key)
    revision &+= 1
  }

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

  func data(forKey key: String) -> Data? {
    if let cached = cache[key] {
      return cached
    }
    let data: Data?
    if let database {
      data = cacheIsComplete ? nil : try? database.preference(forKey: key)
    } else {
      data = fallback[key]
    }
    cache[key] = data
    return data
  }
}

struct LocalPreferenceChange {
  let key: String
  let data: Data?
  let canDecode: (Data) -> Bool
}

private final class PendingPreferenceWrites: @unchecked Sendable {
  struct Batch {
    var clearsAll = false
    var changes: [String: Data?] = [:]
  }

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
