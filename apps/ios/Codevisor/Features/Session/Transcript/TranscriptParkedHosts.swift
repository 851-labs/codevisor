@MainActor
final class TranscriptParkedHosts {
  private static let maximumCount = 16
  private static let maximumSpareCount = 12
  private static let maximumRetiringCount = 32
  private var hosts: [String: TranscriptRowHost] = [:]
  private var leastRecentlyUsedKeys: [String] = []
  private var spares: [TranscriptRowHost] = []
  private var retiring: [TranscriptRowHost] = []

  var hasRetiringHosts: Bool { !retiring.isEmpty }

  func insert(_ host: TranscriptRowHost, for key: String) {
    if let replaced = hosts[key] { recycle(replaced) }
    hosts[key] = host
    leastRecentlyUsedKeys.removeAll { $0 == key }
    leastRecentlyUsedKeys.append(key)
    while leastRecentlyUsedKeys.count > Self.maximumCount {
      let evicted = leastRecentlyUsedKeys.removeFirst()
      if let host = hosts.removeValue(forKey: evicted) { recycle(host) }
    }
  }

  func take(for key: String) -> TranscriptRowHost? {
    guard let host = hosts.removeValue(forKey: key) else { return nil }

    leastRecentlyUsedKeys.removeAll { $0 == key }
    return host
  }

  func takeSpare() -> TranscriptRowHost? {
    spares.popLast() ?? retiring.popLast()
  }

  func recycle(_ host: TranscriptRowHost) {
    host.prepareForReuse()
    if spares.count < Self.maximumSpareCount {
      spares.append(host)
    } else if retiring.count < Self.maximumRetiringCount {
      retiring.append(host)
    } else {
      host.detachFromParent()
    }
  }

  func drainRetiringHosts(limit: Int) {
    for _ in 0..<max(0, limit) {
      guard let host = retiring.popLast() else { return }
      host.detachFromParent()
    }
  }

  func remove(keys: [String]) {
    for key in keys {
      if let host = hosts.removeValue(forKey: key) { recycle(host) }
    }
    leastRecentlyUsedKeys.removeAll { keys.contains($0) }
  }

  func remove(where isStale: (String) -> Bool) {
    remove(keys: leastRecentlyUsedKeys.filter(isStale))
  }

  func removeAll() {
    for host in Array(hosts.values) + spares + retiring {
      host.detachFromParent()
    }
    hosts.removeAll(keepingCapacity: false)
    leastRecentlyUsedKeys.removeAll(keepingCapacity: false)
    spares.removeAll(keepingCapacity: false)
    retiring.removeAll(keepingCapacity: false)
  }
}
