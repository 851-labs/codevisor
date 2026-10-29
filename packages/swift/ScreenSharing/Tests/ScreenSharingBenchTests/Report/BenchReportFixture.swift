import Foundation
import ScreenSharingBench

enum BenchReportFixture {
  static var report: BenchReport {
    BenchReport(
      run: BenchRun(
        id: "gha-12345-1", tier: 2, startedAt: Date(timeIntervalSince1970: 1_793_268_000), gitSha: "e3e2b0613",
        trigger: "nightly"),
      environment: environment, calibration: calibration, results: [appleResult, codevisorResult],
      comparisons: [
        BenchComparison(
          scene: "scroll", resolution: "R1", network: "N0", metric: "image_age_ms.p50", appleHp: [48, 50, 51],
          codevisor: [61, 62, 60], noiseBandMs: 3, verdict: .appleFaster)
      ])
  }

  static func distribution(_ samples: [Double]) -> BenchDistribution {
    BenchDistribution(samples)!
  }

  private static var environment: BenchEnvironment {
    BenchEnvironment(
      host: BenchMachine(
        name: "tamale", chip: "Apple M6", os: "27.2", display: "1920x1080@60 1x", load1AtStart: 0.6,
        thermal: "nominal", spotlightBusy: false),
      viewer: BenchMachine(
        name: "croissant", chip: "Apple M6", os: "27.2", display: "1920x1080@60 1x", load1AtStart: 0.4,
        thermal: "nominal", spotlightBusy: false),
      link: "en0 1000baseT", clock: BenchClockQuality(epsilonMs: 0.33, driftPpm: 2.1, residualMs: 0.05))
  }

  private static var calibration: BenchCalibration {
    BenchCalibration(
      observerAgreementMs: distribution([0, 0, 0, 16.7]), nullSharingImageAgeMs: distribution([18.1, 24.9, 41]),
      localI2pMs: distribution([30.2, 38, 52.1]),
      observerInterference: .init(fpsDeltaPct: 0.8, cpuDeltaPct: 1.9))
  }

  private static var appleResult: BenchResult {
    var result = BenchResult(
      system: .appleHP, scene: "scroll", resolution: "R1", network: "N0", repetition: 1, seed: 7)
    result.imageAgeMs = distribution([48, 50, 52, 90])
    result.imageAgeAboveFloorMs = .init(p50: 31.9)
    result.updatesPerS = 59.6
    result.shownRatio = 0.99
    result.skippedVersions = 12
    result.gapMs = distribution([16.7, 16.7, 18, 50.1])
    result.judderMs = 1.3
    result.freezes = BenchFreezes(count: 0, totalMs: 0, ratio: 0, perMinute: 0, pauses: 0, pausesTotalMs: 0)
    result.bitrateMbps = .init(p50: 41.2, p95: 77, max: 120.4, totalMb: 310.2)
    result.cpuPct = .init(host: .init(p50: 31, p95: 44), viewer: .init(p50: 18, p95: 22))
    result.energyMw = .init(host: 820, viewer: 610)
    result.unreadableFraction = 0.001
    return result
  }

  private static var codevisorResult: BenchResult {
    var result = BenchResult(
      system: .codevisor, scene: "test-cards", resolution: "R1", network: "N3", repetition: 2, seed: 7)
    result.imageAgeMs = distribution([60, 61, 75])
    result.e2eMs = distribution([38, 40, 52])
    result.e2eEndpoint = .committed
    result.updatesPerS = 31.5
    result.shownRatio = 0.97
    result.text = BenchTextFidelity(
      psnrY: 41.2, psnrYText: 38.9, ssimY: 0.987, psnrCbcr: 36.1, deltaE00Mean: 1.4, deltaE00P95: 3.2, oneToOne: true)
    var stages = BenchStageTimings()
    stages.encode = distribution([4.1, 5, 9.8])
    stages.decodeQueue = distribution([12, 15, 31])
    stages.networkResidual = distribution([0.4, 0.6, 2.2])
    stages.timingFrameCheck = BenchTimingFrameCheck(
      timingFrames: [BenchTimingFrame(statisticsValue: "1,100,100,105,0,0,0,0,0,0,120,121,130,0,1")!],
      frames: [
        BenchFrameTimestamps(
          sourceNs: 0, captureCallbackNs: 0, encodeSubmitNs: 0, encodeOutputNs: 5_000_000, decodeInputNs: 20_000_000,
          decodeOutputNs: 21_000_000, renderCommitNs: 22_000_000)
      ], timingClockOffsetNs: -100_000_000)
    result.stagesMs = stages
    result.drops = .init(network: 3, jitter: 1, encoder: 0, capture: 0)
    result.codecErrors = 0
    var media = BenchRelayStatistics()
    media.packets = 9_981
    media.bytes = 11_204_311
    media.lost = 104
    media.firstLosses = [172, 212, 398]
    var feedback = BenchRelayStatistics()
    feedback.packets = 1_204
    feedback.bytes = 96_320
    feedback.lost = 11
    feedback.firstLosses = [40]
    result.relay = BenchRelayReport(media: media, feedback: feedback)
    result.unreadableFraction = 0.02
    result.valid = false
    result.invalidReason = "unreadable captures above 1%"
    return result
  }
}
