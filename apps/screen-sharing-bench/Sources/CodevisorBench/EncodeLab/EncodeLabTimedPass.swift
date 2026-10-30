import ScreenSharing
import ScreenSharingBenchScenes

@MainActor
struct EncodeLabTimedPass {
  static let tickNs = Int64(1_000_000_000 / BenchSceneTimeline.ticksPerSecond)
  static let startDelayNs: Int64 = 100_000_000

  let setup: BenchSceneSetup
  let config: EncodeLabConfig
  let ticks: Int
  let warmUpTicks: Int

  func run() async throws -> EncodeLabTrace {
    let source = try EncodeLabFrameSource(setup: setup, config: config)
    let encoder = try makeEncoder()
    let events = try await pace(source: source, encoder: encoder)
    encoder.finish()
    return EncodeLabTrace(
      config: config, events: events, outputs: encoder.outputs, warmUpTicks: warmUpTicks, ticks: ticks)
  }

  private func makeEncoder() throws -> any EncodeLabFrameEncoder {
    switch config.engine {
    case .videoToolbox: try EncodeLabTileSet(config: config)
    case .videoProcessing: try EncodeLabVCPEncoder(config: config)
    }
  }

  private func pace(source: EncodeLabFrameSource, encoder: any EncodeLabFrameEncoder) async throws
    -> [EncodeLabFrameEvent]
  {
    var schedule = EncodeLabSchedule(timeline: setup.scene.timeline, ticks: ticks, refreshTick: refreshTick)
    let pacer = EncodeLabPacer()
    let startNs = ScreenSharingMetrics.nowNs + Self.startDelayNs
    var events: [EncodeLabFrameEvent] = []
    while let step = schedule.next() {
      let refresh = step.refreshes ? config.refreshKind : nil
      let forced: Set<Int> = refresh == nil ? [] : [config.tiles / 2]
      let preparingNs = ScreenSharingMetrics.nowNs
      let prepared = try await source.prepare(version: step.version, forcing: forced)
      let preparedNs = ScreenSharingMetrics.nowNs - preparingNs
      let scheduledNs = startNs + Int64(step.tick) * Self.tickNs
      let frame = events.count
      let submission = try await pacer.run(atNs: scheduledNs) {
        try Self.submit(prepared, frame: frame, tick: step.tick, refresh: refresh, to: encoder)
      }
      events.append(
        EncodeLabFrameEvent(
          frame: frame, version: step.version, tick: step.tick, scheduledNs: scheduledNs, preparedNs: preparedNs,
          submittedNs: submission.submittedNs, returnedNs: submission.returnedNs, encodedTiles: prepared.inputs.keys.sorted(),
          dirtyTiles: prepared.dirtyTiles.count, refresh: refresh))
    }
    return events
  }

  private var refreshTick: Int { warmUpTicks + (ticks - warmUpTicks) / 2 }

  private nonisolated static func submit(
    _ prepared: EncodeLabPreparedFrame, frame: Int, tick: Int, refresh: EncodeLabRefresh?,
    to encoder: any EncodeLabFrameEncoder
  ) throws -> EncodeLabSubmission {
    let submittedNs = ScreenSharingMetrics.nowNs
    try encoder.encode(prepared.inputs, frame: frame, tick: tick, refresh: refresh)
    return EncodeLabSubmission(submittedNs: submittedNs, returnedNs: ScreenSharingMetrics.nowNs)
  }
}
