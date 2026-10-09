import Foundation

/// Stamps this device's writes to replicated navigation records.
///
/// A hybrid logical clock: wall-clock milliseconds, a counter for writes in
/// the same millisecond, and this device's id. Stamps compare as strings, so
/// every machine and device orders two writes the same way, and the clock
/// never issues a stamp at or below one it has seen, so a later edit here
/// wins even over a device whose wall clock runs ahead.
@MainActor
final class NavigationClock {
  nonisolated static let deviceKey = "navigation-clock-device-v1"

  let deviceId: String
  private var lastMilliseconds: Int64 = 0
  private var counter = 0
  private let now: () -> Date

  init(store: any PersistenceStore, now: @escaping () -> Date) {
    self.now = now
    if let data = store.loadData(forKey: Self.deviceKey), let stored = String(data: data, encoding: .utf8),
      !stored.isEmpty
    {
      deviceId = stored
    } else {
      let fresh = UUID().uuidString.lowercased()
      try? store.saveData(Data(fresh.utf8), forKey: Self.deviceKey)
      deviceId = fresh
    }
  }

  /// A stamp newer than every stamp issued or seen so far.
  func next() -> String {
    let wall = Int64(now().timeIntervalSince1970 * 1000)
    if wall > lastMilliseconds {
      lastMilliseconds = wall
      counter = 0
    } else {
      counter += 1
      if counter > 999_999 {
        lastMilliseconds += 1
        counter = 0
      }
    }
    return Self.stamp(milliseconds: lastMilliseconds, counter: counter, device: deviceId)
  }

  /// Keeps later stamps above `revision`, a stamp another writer issued.
  func witness(_ revision: String) {
    let parts = revision.split(separator: "-", maxSplits: 2)
    guard parts.count == 3, let milliseconds = Int64(parts[0]), let seenCounter = Int(parts[1]) else { return }
    if milliseconds > lastMilliseconds {
      lastMilliseconds = milliseconds
      counter = seenCounter
    } else if milliseconds == lastMilliseconds {
      counter = max(counter, seenCounter)
    }
  }

  static func stamp(milliseconds: Int64, counter: Int, device: String) -> String {
    let ms = String(milliseconds)
    let count = String(counter)
    return String(repeating: "0", count: max(0, 13 - ms.count)) + ms + "-"
      + String(repeating: "0", count: max(0, 6 - count.count)) + count + "-" + device
  }
}
