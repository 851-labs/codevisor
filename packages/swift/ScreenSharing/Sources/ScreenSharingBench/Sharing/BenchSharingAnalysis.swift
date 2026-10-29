public struct BenchSharingAnalysis: Sendable, Equatable {
  public let window: BenchSharingWindow
  public let imageAgesMs: [Double]
  public let imageAgeMs: BenchDistribution?
  public let producedVersions: Int?
  public let shownVersions: Int
  public let skippedVersions: Int
  public let updatesPerS: Double
  public let shownRatio: Double?
  public let gapMs: BenchDistribution?
  public let judderMs: Double?
  public let freezes: BenchFreezes?
  public let viewerUnreadableFraction: Double
  public let hostUnreadableFraction: Double?

  public init?(
    host: [BenchObservation]?, viewer: [BenchObservation], viewerNs fromHostNs: (Int64) -> Int64,
    countsFreezes: Bool
  ) {
    let hostVersions = host.map(BenchObservedVersions.init)
    let produced = hostVersions.map { $0.firstPtsNs.mapValues(fromHostNs) }
    let shown = BenchObservedVersions(viewer)
    guard let window = Self.window(host: host, viewer: viewer, mappedBy: fromHostNs) else { return nil }

    let inWindow = produced?.filter { window.contains($0.value) }
    let shownTimes = shown.firstPtsNs.values.filter(window.contains).sorted()
    let gaps = BenchFrameGaps.intervalsMs(between: shownTimes)
    let skipped = inWindow.map { $0.keys.count { shown.firstPtsNs[$0] == nil } } ?? 0
    self.window = window
    imageAgesMs = inWindow.map { Self.agesMs(produced: $0, shown: shown.firstPtsNs) } ?? []
    imageAgeMs = BenchDistribution(imageAgesMs)
    producedVersions = inWindow?.count
    shownVersions = shownTimes.count
    skippedVersions = skipped
    updatesPerS = Double(shownTimes.count) / (window.durationMs / 1_000)
    shownRatio = inWindow.flatMap { Self.ratio(shown: $0.count - skipped, of: $0.count) }
    gapMs = BenchDistribution(gaps)
    judderMs = Self.judderMs(gaps: gapMs, produced: inWindow)
    freezes = countsFreezes ? BenchFreezes(gapsMs: gaps, activeDurationMs: window.durationMs) : nil
    viewerUnreadableFraction = Self.unreadableFraction(viewer, in: window, mappedBy: { $0 })
    hostUnreadableFraction = host.map { Self.unreadableFraction($0, in: window, mappedBy: fromHostNs) }
  }

  private static func window(
    host: [BenchObservation]?, viewer: [BenchObservation], mappedBy map: (Int64) -> Int64
  ) -> BenchSharingWindow? {
    guard let viewerSpan = readableSpanNs(viewer) else { return nil }
    guard let host else { return BenchSharingWindow(spans: [viewerSpan]) }
    guard let hostSpan = readableSpanNs(host) else { return nil }

    return BenchSharingWindow(spans: [map(hostSpan.lowerBound)...map(hostSpan.upperBound), viewerSpan])
  }

  private static func readableSpanNs(_ observations: [BenchObservation]) -> ClosedRange<Int64>? {
    BenchObservedVersions(observations.filter { $0.version != nil }).spanNs
  }

  private static func agesMs(produced: [Int: Int64], shown: [Int: Int64]) -> [Double] {
    produced.compactMap { version, producedNs in
      shown[version].map { Double($0 - producedNs) / 1_000_000 }
    }
  }

  private static func ratio(shown: Int, of total: Int) -> Double? {
    total > 0 ? Double(shown) / Double(total) : nil
  }

  private static func judderMs(gaps: BenchDistribution?, produced: [Int: Int64]?) -> Double? {
    let producedGaps = produced.flatMap { BenchDistribution(BenchFrameGaps.intervalsMs(between: $0.values.sorted())) }
    guard let gaps, let producedGaps else { return nil }

    return gaps.p95 - producedGaps.p95
  }

  private static func unreadableFraction(
    _ observations: [BenchObservation], in window: BenchSharingWindow, mappedBy map: (Int64) -> Int64
  ) -> Double {
    BenchObservedVersions(observations.filter { window.contains(map($0.ptsNs)) }).unreadableFraction
  }
}
