/// Owns prepared UIKit row hosts retained by identity outside the mounted window.
/// Eviction detaches hosting controllers from their parent; taking a host keeps
/// that parent relationship intact so mounting can reuse its prepared content.
@MainActor
final class TranscriptParkedHosts {
  private static let maximumCount = 16
  private var hosts: [String: TranscriptRowHost] = [:]
  private var leastRecentlyUsedKeys: [String] = []

  func insert(_ host: TranscriptRowHost, for key: String) {
    hosts[key]?.detachFromParent()
    hosts[key] = host
    leastRecentlyUsedKeys.removeAll { $0 == key }
    leastRecentlyUsedKeys.append(key)
    while leastRecentlyUsedKeys.count > Self.maximumCount {
      let evicted = leastRecentlyUsedKeys.removeFirst()
      hosts.removeValue(forKey: evicted)?.detachFromParent()
    }
  }

  func take(for key: String) -> TranscriptRowHost? {
    guard let host = hosts.removeValue(forKey: key) else { return nil }
    leastRecentlyUsedKeys.removeAll { $0 == key }
    return host
  }

  func remove(keys: [String]) {
    for key in keys {
      hosts.removeValue(forKey: key)?.detachFromParent()
    }
    leastRecentlyUsedKeys.removeAll { keys.contains($0) }
  }

  func remove(where isStale: (String) -> Bool) {
    remove(keys: leastRecentlyUsedKeys.filter(isStale))
  }

  func removeAll() {
    for host in hosts.values {
      host.detachFromParent()
    }
    hosts.removeAll(keepingCapacity: false)
    leastRecentlyUsedKeys.removeAll(keepingCapacity: false)
  }
}
