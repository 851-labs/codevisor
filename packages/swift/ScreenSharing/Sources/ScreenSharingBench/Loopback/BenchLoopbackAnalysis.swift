public struct BenchLoopbackAnalysis: Sendable {
  private static let nanosecondsPerSecond = 1_000_000_000.0
  private static let nanosecondsPerMillisecond = 1_000_000.0

  public let produced: [BenchVersionEvent]
  public let shown: [BenchVersionEvent]
  public let frames: [BenchFrameTimestamps]
  public let versionsBySourceNs: [Int64: Int]
  private let windowNs: Range<Int64>
  private let cadence: BenchSceneCadence
  private let endpoint: BenchEndpoint

  public init(
    produced: [BenchVersionEvent], frames: [BenchFrameTimestamps], windowNs: Range<Int64>,
    cadence: BenchSceneCadence, endpoint: BenchEndpoint
  ) {
    let producedInWindow = produced.filter { windowNs.contains($0.ns) }
    let versions = Dictionary(producedInWindow.map { ($0.ns, $0.version) }, uniquingKeysWith: min)
    let measured = frames.filter { versions[$0.sourceNs] != nil && $0.endNs(at: endpoint) != nil }
    self.produced = producedInWindow
    self.frames = measured
    versionsBySourceNs = versions
    shown = Self.firstShown(measured, versions: versions, endpoint: endpoint)
    self.windowNs = windowNs
    self.cadence = cadence
    self.endpoint = endpoint
  }

  public func apply(to result: inout BenchResult) {
    result.updatesPerS = Double(shown.count) / windowSeconds
    result.shownRatio = produced.isEmpty ? 0 : Double(shown.count) / Double(produced.count)
    result.skippedVersions = skippedVersions
    result.gapMs = BenchDistribution(gapsMs)
    result.judderMs = result.gapMs.map { $0.p95 - cadence.changeIntervalMs }
    result.freezes = cadence.changesContinuously ? BenchFreezes(gapsMs: gapsMs, activeDurationMs: windowMs) : nil
    result.e2eMs = BenchDistribution(frames.compactMap(e2eMs))
    result.e2eEndpoint = endpoint
    result.e2eOutsideJitterBufferMs = BenchDistribution(frames.compactMap(e2eOutsideJitterBufferMs))
    result.stagesMs = BenchStageTimings(frames: frames)
  }

  private var windowSeconds: Double {
    Double(windowNs.upperBound - windowNs.lowerBound) / Self.nanosecondsPerSecond
  }

  private var windowMs: Double {
    Double(windowNs.upperBound - windowNs.lowerBound) / Self.nanosecondsPerMillisecond
  }

  private var skippedVersions: Int {
    guard let newest = shown.map(\.version).max() else { return 0 }

    let shownVersions = Set(shown.map(\.version))
    return produced.count { $0.version < newest && !shownVersions.contains($0.version) }
  }

  private var gapsMs: [Double] {
    BenchFrameGaps.intervalsMs(between: shown.map(\.ns))
  }

  private func e2eMs(_ frame: BenchFrameTimestamps) -> Double? {
    frame.endNs(at: endpoint).map { Double($0 - frame.sourceNs) / Self.nanosecondsPerMillisecond }
  }

  private func e2eOutsideJitterBufferMs(_ frame: BenchFrameTimestamps) -> Double? {
    guard let e2eMs = e2eMs(frame), let completeNs = frame.frameCompleteNs else { return nil }

    return e2eMs - Double(frame.decodeInputNs - completeNs) / Self.nanosecondsPerMillisecond
  }

  private static func firstShown(
    _ frames: [BenchFrameTimestamps], versions: [Int64: Int], endpoint: BenchEndpoint
  ) -> [BenchVersionEvent] {
    var first: [Int: Int64] = [:]
    for frame in frames {
      guard let version = versions[frame.sourceNs], let endNs = frame.endNs(at: endpoint) else { continue }

      first[version] = min(first[version] ?? endNs, endNs)
    }
    return first.map { BenchVersionEvent(version: $0.key, ns: $0.value) }.sorted { $0.ns < $1.ns }
  }
}
