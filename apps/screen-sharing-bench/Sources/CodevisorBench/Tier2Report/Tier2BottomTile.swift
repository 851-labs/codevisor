import ScreenSharingBench

struct Tier2BottomTile {
  static let sameFrameNs: Int64 = 2_000_000

  let imageAgeMs: BenchDistribution?
  let viewerTornFraction: Double?
  let hostTornFraction: Double?

  init?(_ files: Tier2RunFiles, clock: BenchClockTrack, window: BenchSharingWindow) {
    guard let viewerBottom = files.viewerBottom else { return nil }

    let shown = BenchObservedVersions(viewerBottom).firstPtsNs
    imageAgeMs = files.hostBottom.flatMap { hostBottom in
      let produced = BenchObservedVersions(hostBottom).firstPtsNs.mapValues(clock.localNs(fromRemote:))
      return BenchDistribution(
        produced.filter { window.contains($0.value) }.compactMap { version, producedNs in
          shown[version].map { Double($0 - producedNs) / 1_000_000 }
        })
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
    let events = (Self.readings(top, side: 0) + Self.readings(bottom, side: 1)).sorted { $0.ptsNs < $1.ptsNs }
    var latest: [Int?] = [nil, nil]
    var frames = 0
    var torn = 0
    var index = events.startIndex
    while index < events.endIndex {
      let frameNs = events[index].ptsNs
      while index < events.endIndex, events[index].ptsNs - frameNs <= sameFrameNs {
        latest[events[index].side] = events[index].version
        index += 1
      }
      guard inWindow(frameNs), let shownTop = latest[0], let shownBottom = latest[1] else { continue }

      frames += 1
      if shownTop != shownBottom { torn += 1 }
    }
    return frames > 0 ? Double(torn) / Double(frames) : nil
  }

  private static func readings(
    _ observations: [BenchObservation], side: Int
  ) -> [(ptsNs: Int64, side: Int, version: Int)] {
    observations.compactMap { observation in observation.version.map { (observation.ptsNs, side, $0) } }
  }
}
