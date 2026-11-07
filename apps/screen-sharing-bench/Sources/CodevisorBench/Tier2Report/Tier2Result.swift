import ScreenSharingBench

enum Tier2Result {
  static let defaultResolution = "R1"
  static let defaultNetwork = "N0"

  static func make(_ measurement: Tier2Measurement, system: BenchSystem, analysis: BenchSharingAnalysis) -> BenchResult
  {
    let meta = measurement.files.meta
    var result = BenchResult(
      system: system, scene: meta.scene, resolution: meta.resolutionLabel,
      network: meta.networkLabel,
      repetition: meta.repetition,
      seed: meta.seed)
    result.imageAgeMs = analysis.imageAgeMs
    result.updatesPerS = analysis.updatesPerS
    result.shownRatio = analysis.shownRatio ?? 0
    result.skippedVersions = analysis.skippedVersions
    result.gapMs = analysis.gapMs
    result.judderMs = analysis.judderMs
    result.freezes = analysis.freezes
    result.bitrateMbps = measurement.viewerUsage?.receivedMbps
    result.cpuPct = BenchResult.PerMachine(host: measurement.hostUsage?.cpuPct, viewer: measurement.viewerUsage?.cpuPct)
    result.systemCpuPct = measurement.files.systemCpuPct
    result.displayPhaseMs = measurement.displayPhaseMs
    result.networkCheck = measurement.files.realizedNetwork
    result.energyMw = BenchResult.PerMachine(
      host: measurement.hostUsage?.powerMw, viewer: measurement.viewerUsage?.powerMw)
    result.unreadableFraction = analysis.viewerUnreadableFraction
    result.i2pMs = measurement.inputToPhoton?.answered
    result.text = measurement.textFidelity?.fidelity
    result.text?.streamSize = measurement.streamSize
    if measurement.files.meta.isCodevisor {
      let files = measurement.files
      let engineV2 = BenchSystem.engineV2Systems.contains(system)
      result.stagesMs = Tier2V2Readings.stages(viewer: files.system, host: files.share, engineV2: engineV2)
      result.media = engineV2 ? Tier2V2Readings.counters(viewer: files.system, host: files.share) : nil
    }
    result.valid = measurement.invalidReason == nil
    result.invalidReason = measurement.invalidReason
    return result
  }
}
