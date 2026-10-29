import ScreenSharingBench
import ScreenSharingBenchScenes

struct LoopbackMeasurement {
  private static let nanosecondsPerSecond: Int64 = 1_000_000_000
  private static let unreadableLimit = 0.01

  let scene: BenchScene
  let conditions: BenchNetworkConditions
  let settings: LoopbackSettings
  let clockOffsetNs: Int64
  let relayOriginNs: Int64

  func outcome(_ recording: LoopbackRecording, relay: LoopbackRelay) -> LoopbackOutcome {
    let analysis = BenchLoopbackAnalysis(
      produced: recording.produced.map(continuous), frames: recording.frames.map { $0.shifted(byNs: clockOffsetNs) },
      windowNs: continuousWindow(recording), cadence: LoopbackCadence.of(scene), endpoint: settings.endpoint)
    var result = BenchResult(
      system: .codevisor, scene: scene.rawValue, resolution: settings.resolution.rawValue, network: conditions.id,
      repetition: 1, seed: settings.seed)
    analysis.apply(to: &result)
    result.stagesMs?.timingFrameCheck = BenchTimingFrameCheck(
      timingFrames: Array(recording.readings.timingFrames), frames: analysis.frames, timingClockOffsetNs: clockOffsetNs)
    result.bitrateMbps = bitrate(relay.mediaTraffic, recording: recording)
    result.relay = relay.report
    result.drops = recording.drops
    result.codecErrors = recording.codecErrors
    result.unreadableFraction = recording.unreadableFraction(
      of: recording.produced.filter { window(recording).contains($0.ns) })
    result.invalidReason = recording.codecFailure.map { "the codec failed: \($0)" } ?? invalidReason(result)
    result.valid = result.invalidReason == nil
    return LoopbackOutcome(result: result, frames: lines(analysis), qualityLevel: recording.readings.qualityLevel)
  }

  private var warmUpNs: Int64 { Int64(settings.warmUpSeconds) * Self.nanosecondsPerSecond }
  private var durationNs: Int64 { Int64(settings.durationSeconds) * Self.nanosecondsPerSecond }

  private func continuous(_ event: BenchVersionEvent) -> BenchVersionEvent {
    BenchVersionEvent(version: event.version, ns: event.ns + clockOffsetNs)
  }

  private func window(_ recording: LoopbackRecording) -> Range<Int64> {
    (recording.startNs + warmUpNs)..<(recording.startNs + durationNs)
  }

  private func continuousWindow(_ recording: LoopbackRecording) -> Range<Int64> {
    let window = window(recording)
    return (window.lowerBound + clockOffsetNs)..<(window.upperBound + clockOffsetNs)
  }

  private func bitrate(_ traffic: BenchRelayTraffic, recording: LoopbackRecording) -> BenchResult.Bitrate? {
    let sourceOffsetNs = recording.startNs + clockOffsetNs - relayOriginNs
    let first = (sourceOffsetNs + warmUpNs + Self.nanosecondsPerSecond - 1) / Self.nanosecondsPerSecond
    let end = (sourceOffsetNs + durationNs) / Self.nanosecondsPerSecond
    return traffic.bitrate(fromSecond: Int(first), toSecond: Int(end))
  }

  private func invalidReason(_ result: BenchResult) -> String? {
    if result.e2eMs == nil { return "no frame produced after the warm-up was shown before the scene ended" }
    if result.unreadableFraction > Self.unreadableLimit { return "unreadable barcodes above 1%" }
    return nil
  }

  private func lines(_ analysis: BenchLoopbackAnalysis) -> [LoopbackFrameLine] {
    analysis.frames.compactMap { frame in
      analysis.versionsBySourceNs[frame.sourceNs].map {
        LoopbackFrameLine(scene: scene.rawValue, network: conditions.id, version: $0, timestamps: frame)
      }
    }
  }
}
