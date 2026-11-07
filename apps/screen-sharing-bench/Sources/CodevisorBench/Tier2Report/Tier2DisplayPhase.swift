import Foundation
import ScreenSharingBench

enum Tier2DisplayPhase {
  static let refreshNs = 1_000_000_000.0 / 60
  static let minimumCoherence = 0.9
  private static let wholeRefreshesNs: Int64 = 50_000_000

  static func ms(host: [BenchObservation]?, viewer: [BenchObservation], clock: BenchClockTrack?) -> Double? {
    guard let host, let clock,
      let hostPhase = meanPhaseNs(host.map { clock.localNs(fromRemote: $0.ptsNs) }),
      let viewerPhase = meanPhaseNs(viewer.map(\.ptsNs))
    else { return nil }

    return wrapped(viewerPhase - hostPhase) / 1_000_000
  }

  static func meanMs(_ phasesMs: [Double]) -> Double? {
    meanPhaseNs(phasesNs: phasesMs.map { $0 * 1_000_000 }).map { $0 / 1_000_000 }
  }

  static func meanPhaseNs(_ times: [Int64]) -> Double? {
    meanPhaseNs(phasesNs: times.map { Double($0 % wholeRefreshesNs) })
  }

  private static func meanPhaseNs(phasesNs: [Double]) -> Double? {
    guard !phasesNs.isEmpty else { return nil }

    let angles = phasesNs.map { 2 * Double.pi * $0 / refreshNs }
    let sine = angles.map(sin).reduce(0, +) / Double(angles.count)
    let cosine = angles.map(cos).reduce(0, +) / Double(angles.count)
    guard (sine * sine + cosine * cosine).squareRoot() >= minimumCoherence else { return nil }

    return wrapped(atan2(sine, cosine) / (2 * Double.pi) * refreshNs)
  }

  private static func wrapped(_ phaseNs: Double) -> Double {
    let remainder = phaseNs.truncatingRemainder(dividingBy: refreshNs)
    return remainder < 0 ? remainder + refreshNs : remainder
  }
}
