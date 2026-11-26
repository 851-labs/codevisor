struct ScreenSharingRealignment {
  static let starvedAfterNs: Int64 = 2_000_000
  static let spacingNs: Int64 = 1_000_000_000
  static let fallbackSlackNs: Int64 = 4_000_000
  static let trackedArrivals = 5

  var periodNs: Int64 = 16_666_667
  private var arrivals: [Int64] = []
  private var starvedAtNs: Int64?
  private var lastRealignNs: Int64?

  private var holdNs: Int64 { periodNs * 5 / 4 }

  private var atFullRate: Bool {
    guard arrivals.count == Self.trackedArrivals else { return false }

    return zip(arrivals, arrivals.dropFirst()).allSatisfy { $1 - $0 < holdNs }
  }

  mutating func arrived(atNs nowNs: Int64) {
    arrivals.append(nowNs)
    if arrivals.count > Self.trackedArrivals { arrivals.removeFirst() }
  }

  mutating func committed(waitedNs: Int64, atNs nowNs: Int64) -> Bool {
    let spaced = lastRealignNs.map { nowNs - $0 > Self.spacingNs } ?? true
    guard waitedNs > Self.starvedAfterNs, atFullRate, spaced else { return false }

    starvedAtNs = nowNs
    return true
  }

  mutating func holds(atNs nowNs: Int64) -> Int64? {
    guard let starvedAtNs else { return nil }

    let elapsed = nowNs - starvedAtNs
    guard elapsed < holdNs else {
      finish(atNs: nowNs)
      return nil
    }

    return 2 * periodNs + Self.fallbackSlackNs - elapsed
  }

  mutating func finish(atNs nowNs: Int64) {
    guard starvedAtNs != nil else { return }

    starvedAtNs = nil
    lastRealignNs = nowNs
  }
}
