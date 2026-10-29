import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes

actor SyntheticSource: LoopbackSource {
  private static let tick = Duration.nanoseconds(1_000_000_000 / BenchSceneTimeline.ticksPerSecond)
  private static let ticksRenderedAhead = 3

  private let generator: BenchSceneGenerator
  private let timeline: BenchSceneTimeline
  private let sink: any ScreenSharingFrameSink
  private var scaler: FrameScaler?
  private var ticksPerFrame = 1
  private var lastVersion: Int?
  private var prepared: [Int: Task<BenchSceneFrame, any Error>] = [:]
  private(set) var produced: [BenchVersionEvent] = []

  init(setup: BenchSceneSetup, sink: any ScreenSharingFrameSink) throws {
    generator = try BenchSceneGenerator(setup: setup)
    timeline = setup.scene.timeline
    self.sink = sink
  }

  func run(for duration: Duration) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    var deadline = start
    while deadline < start + duration {
      try await clock.sleep(until: deadline, tolerance: .zero)
      let tick = Int((clock.now - start) / Self.tick)
      if tick.isMultiple(of: ticksPerFrame) { try await show(version: timeline.version(atTick: tick)) }
      prepare(ticksAfter: tick)
      deadline = start + Self.tick * (tick + 1)
    }
  }

  func adapt(to configuration: ScreenSharingVideoConfiguration) throws {
    let canvas = generator.setup.canvas
    let isCanvasSize = configuration.width == canvas.pixelWidth && configuration.height == canvas.pixelHeight
    scaler = isCanvasSize ? nil : try FrameScaler(width: configuration.width, height: configuration.height)
    ticksPerFrame = max(1, BenchSceneTimeline.ticksPerSecond / configuration.framesPerSecond)
  }

  private func show(version: Int) async throws {
    guard version != lastVersion else { return }

    let frame = try await frame(forVersion: version)
    let pixels = try scaler?.scaled(frame.pixelBuffer) ?? frame.pixelBuffer
    let timestampNs = ScreenSharingMetrics.nowNs
    sink.push(ScreenSharingVideoFrame(pixelBuffer: pixels, timestampNs: timestampNs))
    lastVersion = version
    produced.append(BenchVersionEvent(version: version, ns: timestampNs))
  }

  private func frame(forVersion version: Int) async throws -> BenchSceneFrame {
    guard let rendering = prepared.removeValue(forKey: version) else {
      return try await generator.frame(forVersion: version)
    }

    return try await rendering.value
  }

  private func prepare(ticksAfter tick: Int) {
    let shownTicks = (1...Self.ticksRenderedAhead).map { tick + $0 * ticksPerFrame }
    let upcoming = Set(shownTicks.map { timeline.version(atTick: $0 - $0 % ticksPerFrame) })
    for (version, stale) in prepared where !upcoming.contains(version) {
      stale.cancel()
      prepared[version] = nil
    }
    let generator = generator
    for version in upcoming where version != lastVersion && prepared[version] == nil {
      prepared[version] = Task { try await generator.frame(forVersion: version) }
    }
  }
}
