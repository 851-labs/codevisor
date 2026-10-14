import CodevisorClient

enum SyncClock {
  static func compare(_ a: ServerSyncTimestamp, _ b: ServerSyncTimestamp) -> Int {
    if a.wallMs != b.wallMs { return a.wallMs < b.wallMs ? -1 : 1 }
    if a.counter != b.counter { return a.counter < b.counter ? -1 : 1 }
    if a.deviceId != b.deviceId { return a.deviceId < b.deviceId ? -1 : 1 }
    return 0
  }

  static func latest(in entries: [ServerSyncEntry]) -> ServerSyncTimestamp? {
    entries.map(\.timestamp).max { compare($0, $1) < 0 }
  }

  static func next(
    after: ServerSyncTimestamp?,
    deviceId: String,
    nowMs: Int
  ) -> ServerSyncTimestamp {
    guard let after, nowMs <= after.wallMs else {
      return ServerSyncTimestamp(wallMs: nowMs, counter: 0, deviceId: deviceId)
    }
    return ServerSyncTimestamp(
      wallMs: after.wallMs,
      counter: after.counter + 1,
      deviceId: deviceId
    )
  }

  static func merge(
    _ current: [ServerSyncEntry],
    _ incoming: [ServerSyncEntry]
  ) -> (merged: [ServerSyncEntry], changed: [ServerSyncEntry]) {
    var byKey: [String: ServerSyncEntry] = [:]
    for entry in current {
      byKey[entry.key] = entry
    }
    var changed: [ServerSyncEntry] = []
    applyIncoming(incoming, to: &byKey, changed: &changed)
    let merged = byKey.values.sorted { $0.key < $1.key }
    return (merged, changed)
  }

  private static func applyIncoming(
    _ incoming: [ServerSyncEntry],
    to byKey: inout [String: ServerSyncEntry],
    changed: inout [ServerSyncEntry]
  ) {
    for entry in incoming {
      if let existing = byKey[entry.key], compare(entry.timestamp, existing.timestamp) <= 0 {
        continue
      }
      byKey[entry.key] = entry
      changed.append(entry)
    }
  }
}
