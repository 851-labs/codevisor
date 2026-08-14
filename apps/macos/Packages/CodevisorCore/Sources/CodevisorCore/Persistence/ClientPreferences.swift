import Foundation
import Observation
import SwiftUI

/// SQLite-backed replacement for the app's direct `UserDefaults` usage.
///
/// The singleton is configured by `ClientStorageBootstrap` before either
/// platform constructs its view hierarchy. Reads intentionally touch
/// `revision`, allowing Swift Observation to invalidate a view that accesses a
/// value through `@ClientPreference`.
@MainActor
@Observable
public final class ClientPreferences {
    public static let shared = ClientPreferences()

    private var database: ClientDatabase?
    private var fallback: [String: Data] = [:]
    private var revision: UInt64 = 0
    /// Write-through cache of raw preference blobs, keyed by preference key.
    /// A stored `nil` records a confirmed-absent key so misses don't re-query
    /// SQLite. All writes go through this class after `configure(database:)`,
    /// which resets the cache, so entries can never go stale. Ignored by
    /// Observation: views invalidate via `revision`, and populating the cache
    /// during a read must not mutate observed state.
    @ObservationIgnored private var cache: [String: Data?] = [:]

    public init(database: ClientDatabase? = nil) {
        self.database = database
    }

    public func configure(database: ClientDatabase) {
        self.database = database
        cache.removeAll()
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
            if let database {
                try database.setPreference(data, forKey: key)
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
        do {
            if let database {
                try database.removePreference(forKey: key)
            } else {
                fallback[key] = nil
            }
            cache.updateValue(nil, forKey: key)
            revision &+= 1
        } catch {
            Log.persistence.error(
                "Failed to remove preference \(key, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    public func removeAll() {
        do {
            if let database {
                try database.removeAllPreferences()
            } else {
                fallback.removeAll()
            }
            cache.removeAll()
            revision &+= 1
        } catch {
            Log.persistence.error(
                "Failed to clear client preferences: \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func data(forKey key: String) -> Data? {
        if let cached = cache[key] {
            return cached
        }
        let data: Data?
        if let database {
            data = try? database.preference(forKey: key)
        } else {
            data = fallback[key]
        }
        cache[key] = data
        return data
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
