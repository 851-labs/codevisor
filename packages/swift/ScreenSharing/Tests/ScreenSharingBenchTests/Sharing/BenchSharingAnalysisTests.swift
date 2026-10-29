import ScreenSharingBench
import Testing

struct BenchSharingAnalysisTests {
  private static let refreshNs: Int64 = 16_666_667
  private static let sceneStartNs: Int64 = 1_000_000_000
  private static let viewerMinusHostNs: Int64 = 1_000_000_000_000
  private static let imageAgeNs: Int64 = 30_000_000
  private static let versions = 1...1_200

  @Test func imageAgeCountsEveryShownVersionAfterWarmUpAndSkippedVersionsApart() throws {
    let analysis = try #require(
      BenchSharingAnalysis(
        host: Self.host(), viewer: Self.viewer(skipping: [400]), viewerNs: { $0 + Self.viewerMinusHostNs },
        countsFreezes: true))
    let produced = try #require(analysis.producedVersions)

    #expect(analysis.window.startNs == Self.viewerNs(onGlassOf: 1) + BenchSharingWindow.warmUpNs)
    #expect(analysis.window.endNs == Self.hostNs(of: Self.versions.upperBound) + Self.viewerMinusHostNs - 2_000_000_000)
    #expect(analysis.imageAgeMs?.p50 == 30 && analysis.imageAgeMs?.max == 30)
    #expect(analysis.imageAgeMs?.count == produced - 1)
    #expect(analysis.skippedVersions == 1)
    #expect(analysis.shownRatio == Double(produced - 1) / Double(produced))
    #expect(abs(analysis.updatesPerS - 60) < 0.1)
    #expect(abs((analysis.gapMs?.max ?? 0) - 33.333) < 0.001)
    #expect(analysis.freezes?.count == 0)
    #expect(analysis.viewerUnreadableFraction == 1 / Double(analysis.shownVersions + 1))
    #expect(analysis.hostUnreadableFraction == 0)
  }

  @Test func aStallLongerThanTheFreezeThresholdIsAFreeze() throws {
    let analysis = try #require(
      BenchSharingAnalysis(
        host: Self.host(), viewer: Self.viewer(skipping: Set(500..<524)), viewerNs: { $0 + Self.viewerMinusHostNs },
        countsFreezes: true))

    #expect(analysis.freezes?.count == 1)
    #expect(analysis.skippedVersions == 24)
  }

  @Test func withoutAHostObserverOnlyTheViewerSideIsMeasured() throws {
    let analysis = try #require(
      BenchSharingAnalysis(host: nil, viewer: Self.viewer(skipping: []), viewerNs: { $0 }, countsFreezes: false))

    #expect(analysis.window.startNs == Self.viewerNs(onGlassOf: 1) + BenchSharingWindow.warmUpNs)
    #expect(analysis.imageAgeMs == nil && analysis.producedVersions == nil && analysis.freezes == nil)
    #expect(abs(analysis.updatesPerS - 60) < 0.1)
  }

  private static func hostNs(of version: Int) -> Int64 {
    sceneStartNs + Int64(version) * refreshNs
  }

  private static func viewerNs(onGlassOf version: Int) -> Int64 {
    hostNs(of: version) + viewerMinusHostNs + imageAgeNs
  }

  private static func host() -> [BenchObservation] {
    [BenchObservation(ptsNs: sceneStartNs / 2, callbackNs: 0, reading: .checksumMismatch)]
      + versions.map { BenchObservation(ptsNs: hostNs(of: $0), callbackNs: 0, reading: .version($0)) }
  }

  private static func viewer(skipping skipped: Set<Int>) -> [BenchObservation] {
    let shown = versions.filter { !skipped.contains($0) }.map {
      BenchObservation(ptsNs: viewerNs(onGlassOf: $0), callbackNs: 0, reading: .version($0))
    }
    let torn = BenchObservation(ptsNs: viewerNs(onGlassOf: 600) + 1, callbackNs: 0, reading: .ambiguousBlock(2))
    return (shown + [torn]).sorted { $0.ptsNs < $1.ptsNs }
  }
}
