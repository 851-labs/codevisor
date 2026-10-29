public struct BenchObservedVersions: Sendable, Equatable {
  public let firstPtsNs: [Int: Int64]
  public let frames: Int
  public let unreadableFrames: Int
  public let spanNs: ClosedRange<Int64>?

  public init(_ observations: [BenchObservation]) {
    var firstPtsNs: [Int: Int64] = [:]
    for observation in observations {
      guard let version = observation.version else { continue }

      firstPtsNs[version] = min(firstPtsNs[version] ?? observation.ptsNs, observation.ptsNs)
    }
    self.firstPtsNs = firstPtsNs
    frames = observations.count
    unreadableFrames = observations.count { $0.version == nil }
    let times = observations.map(\.ptsNs)
    spanNs = times.min().flatMap { first in times.max().map { first...$0 } }
  }

  public var unreadableFraction: Double {
    frames > 0 ? Double(unreadableFrames) / Double(frames) : 0
  }

  public func delaysMs(since startNs: [Int: Int64]) -> [Double] {
    firstPtsNs.keys.sorted().compactMap { version in
      guard let start = startNs[version], let shown = firstPtsNs[version] else { return nil }

      return Double(shown - start) / 1_000_000
    }
  }
}
