import Foundation

/// A bounded cache of native presentations. Active owners are protected;
/// detached entries are discarded in least-recently-used order. Platforms
/// decide when to trim so deallocation stays outside navigation updates.
@MainActor
public final class TranscriptPresentationCache<Key: Hashable, Value: AnyObject> {
  private var values: [Key: Value] = [:]
  private var accessOrder: [Key] = []
  private let detachedLimit: Int
  private let isAttached: (Value) -> Bool
  private let discard: (Value) -> Void

  public init(
    detachedLimit: Int,
    isAttached: @escaping (Value) -> Bool,
    discard: @escaping (Value) -> Void
  ) {
    self.detachedLimit = max(0, detachedLimit)
    self.isAttached = isAttached
    self.discard = discard
  }

  public var count: Int { values.count }

  public func value(for key: Key) -> Value? {
    guard let value = values[key] else { return nil }
    touch(key)
    return value
  }

  public func insert(_ value: Value, for key: Key) {
    if let previous = values.updateValue(value, forKey: key), previous !== value {
      discard(previous)
    }
    touch(key)
  }

  public func remove(where predicate: (Key) -> Bool) {
    for key in accessOrder.filter(predicate) { remove(key) }
  }

  public func remove(_ key: Key) {
    accessOrder.removeAll { $0 == key }
    if let value = values.removeValue(forKey: key) { discard(value) }
  }

  public func trim(excluding protectedKey: Key? = nil, discardingAllDetached: Bool = false) {
    let detached = accessOrder.filter { key in
      key != protectedKey && values[key].map { !isAttached($0) } == true
    }
    let limit = discardingAllDetached ? 0 : detachedLimit
    for key in detached.prefix(max(0, detached.count - limit)) { remove(key) }
  }

  private func touch(_ key: Key) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }
}
