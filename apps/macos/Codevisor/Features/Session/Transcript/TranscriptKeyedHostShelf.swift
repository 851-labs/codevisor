import AppKit

@MainActor
struct TranscriptKeyedHostShelf<Host: TranscriptMountedRowHost> {
  private let limit: Int
  private let spareLimit = 8
  private var parked: [String: Host] = [:]
  private var order: [String] = []
  private var spares: [Host] = []

  init(limit: Int) {
    self.limit = limit
  }

  mutating func take(for key: String, make: () -> Host) -> Host {
    if let host = parked.removeValue(forKey: key) {
      order.removeAll { $0 == key }
      return host
    }
    return spares.popLast() ?? make()
  }

  mutating func park(_ host: Host, for key: String) {
    if let replaced = parked.updateValue(host, forKey: key), replaced !== host { recycle(replaced) }
    order.removeAll { $0 == key }
    order.append(key)
    while order.count > limit {
      if let evicted = parked.removeValue(forKey: order.removeFirst()) { recycle(evicted) }
    }
  }

  mutating func recycle(_ host: Host) {
    if spares.count < spareLimit { spares.append(host) }
  }

  mutating func removeAll() {
    parked.removeAll()
    order.removeAll()
  }
}
