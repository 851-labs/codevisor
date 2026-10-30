import ScreenSharingBench
import ScreenSharingBenchScenes

struct EncodeLabSummarizer {
  static let lateSubmitNs: Int64 = 2_000_000

  let trace: EncodeLabTrace

  func summarize(into result: inout EncodeLabResult, quality: EncodeLabQualityPass.Result) {
    let measured = trace.events.filter { $0.tick >= trace.warmUpTicks }
    let outputs = measured.map { trace.outputs(ofFrame: $0.frame) }
    result.frames = measured.count
    result.tilesPerFrame = mean(outputs.map { Double($0.filter { !$0.dropped }.count) })
    result.encodeMs = BenchDistribution(zip(measured, outputs).compactMap { encodeMs($0, $1, latest: true) })
    result.firstTileMs = BenchDistribution(zip(measured, outputs).compactMap { encodeMs($0, $1, latest: false) })
    result.chroma = EncodeLabChromaFormat.of(trace.firstOutput?.sample)
    result.prepareMs = BenchDistribution(measured.map { Double($0.preparedNs) / 1e6 })
    result.submitBlockMs = BenchDistribution(measured.map { Double($0.returnedNs - $0.submittedNs) / 1e6 })
    result.repeatFrames = measured.filter(\.repeats).count
    result.lateSubmits = measured.filter { $0.submittedNs - $0.scheduledNs > Self.lateSubmitNs }.count
    result.dropped = outputs.joined().filter(\.dropped).count
    result.megabitsPerSecond = megabitsPerSecond(outputs.joined())
    result.frameKilobytes = BenchDistribution(outputs.map { Double($0.map(\.bytes).reduce(0, +)) / 1000 })
    result.firstFrame = trace.events.first.flatMap { EncodeLabFrameCost(outputs: trace.outputs(ofFrame: 0), event: $0) }
    result.refresh = refreshCost
    result.quality = EncodeLabQualitySummary(quality.samples, atNativeSize: quality.atNativeSize)
    result.decodeMs = BenchDistribution(Array(quality.decodeMs.dropFirst(trace.events.count - measured.count)))
  }

  private var refreshCost: EncodeLabFrameCost? {
    guard let event = trace.events.first(where: { $0.refresh != nil }) else { return nil }

    return EncodeLabFrameCost(outputs: trace.outputs(ofFrame: event.frame), event: event, only: trace.refreshTile)
  }

  private func encodeMs(_ event: EncodeLabFrameEvent, _ outputs: [EncodeLabTileOutput], latest: Bool) -> Double? {
    let times = outputs.filter { !$0.dropped }.map(\.outputNs)
    guard let chosen = latest ? times.max() : times.min() else { return nil }

    return Double(chosen - event.submittedNs) / 1e6
  }

  private func megabitsPerSecond(_ outputs: some Sequence<EncodeLabTileOutput>) -> Double {
    let seconds = Double(trace.ticks - trace.warmUpTicks) / Double(BenchSceneTimeline.ticksPerSecond)
    return Double(outputs.map(\.bytes).reduce(0, +)) * 8 / 1e6 / seconds
  }

  private func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
  }
}
