import ScreenSharingBench

struct Tier2BottomTile {
  static let matchToleranceNs: Int64 = 2_000_000

  let imageAgeMs: BenchDistribution?
  let viewerTornFraction: Double?
  let hostTornFraction: Double?

  init?(_ files: Tier2RunFiles, clock: BenchClockTrack, window: BenchSharingWindow) {
    guard let viewerBottom = files.viewerBottom else { return nil }

    imageAgeMs = files.hostBottom.flatMap { hostBottom in
      BenchSharingAnalysis(
        host: hostBottom, viewer: viewerBottom, viewerNs: clock.localNs(fromRemote:), countsFreezes: false)?
        .imageAgeMs
    }
    viewerTornFraction = Self.tornFraction(top: files.viewer, bottom: viewerBottom) { window.contains($0) }
    hostTornFraction = files.hostBottom.flatMap { hostBottom in
      files.host.flatMap { host in
        Self.tornFraction(top: host, bottom: hostBottom) { window.contains(clock.localNs(fromRemote: $0)) }
      }
    }
  }

  static func tornFraction(
    top: [BenchObservation], bottom: [BenchObservation], inWindow: (Int64) -> Bool
  ) -> Double? {
    let tops = top.compactMap { observation in observation.version.map { (observation.ptsNs, $0) } }
      .filter { inWindow($0.0) }.sorted { $0.0 < $1.0 }
    let pairs = bottom.compactMap { observation -> (Int, Int)? in
      guard let version = observation.version, inWindow(observation.ptsNs),
        let match = nearest(observation.ptsNs, in: tops)
      else { return nil }

      return (match, version)
    }
    guard !pairs.isEmpty else { return nil }

    return Double(pairs.count { $0.0 != $0.1 }) / Double(pairs.count)
  }

  private static func nearest(_ ptsNs: Int64, in sorted: [(Int64, Int)]) -> Int? {
    var low = 0
    var high = sorted.count
    while low < high {
      let middle = (low + high) / 2
      if sorted[middle].0 < ptsNs { low = middle + 1 } else { high = middle }
    }
    let candidates = [low - 1, low].filter(sorted.indices.contains)
    guard let best = candidates.min(by: { abs(sorted[$0].0 - ptsNs) < abs(sorted[$1].0 - ptsNs) }),
      abs(sorted[best].0 - ptsNs) <= matchToleranceNs
    else { return nil }

    return sorted[best].1
  }
}
