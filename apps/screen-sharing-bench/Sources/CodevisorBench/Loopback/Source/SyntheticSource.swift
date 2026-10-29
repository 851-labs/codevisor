import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes

actor SyntheticSource: LoopbackSource {
  private static let framesRenderedAhead = 3

  private let generator: BenchSceneGenerator
  private let timeline: BenchSceneTimeline
  private let pusher: SourcePusher
  private var rendering: [Int: Task<Void, Never>] = [:]
  private var finished = false

  init(setup: BenchSceneSetup, sink: any ScreenSharingFrameSink) throws {
    generator = try BenchSceneGenerator(setup: setup)
    timeline = setup.scene.timeline
    pusher = SourcePusher(timeline: setup.scene.timeline, sink: sink)
  }

  var produced: [BenchVersionEvent] {
    pusher.shelf.withLock { $0.produced }
  }

  func run(for duration: Duration) async throws {
    let ticks = Int(duration / .nanoseconds(SourcePusher.tickNs))
    for version in upcoming(after: -1) { try await prepare(version) }
    await pusher.run(ticks: ticks) { tick in Task { await self.prepareAhead(after: tick) } }
    finished = true
    for task in rendering.values { task.cancel() }
    let missed = pusher.shelf.withLock { $0.missed }
    if missed > 0 {
      BenchConsole.error("synthetic source: \(missed) versions weren't rendered in time and were skipped")
    }
  }

  func adapt(to configuration: ScreenSharingVideoConfiguration) throws {
    let canvas = generator.setup.canvas
    let isCanvasSize = configuration.width == canvas.pixelWidth && configuration.height == canvas.pixelHeight
    let scaler = isCanvasSize ? nil : try FrameScaler(width: configuration.width, height: configuration.height)
    let ticksPerFrame = max(1, BenchSceneTimeline.ticksPerSecond / configuration.framesPerSecond)
    pusher.shelf.withLock { shelf in
      shelf.scaler = scaler
      shelf.ticksPerFrame = ticksPerFrame
    }
  }

  private func prepareAhead(after tick: Int) {
    guard !finished else { return }

    let versions = upcoming(after: tick)
    pusher.shelf.withLock { shelf in shelf.ready = shelf.ready.filter { versions.contains($0.key) } }
    for version in versions where rendering[version] == nil && !isReady(version) {
      rendering[version] = Task { try? await self.prepare(version) }
    }
  }

  private func prepare(_ version: Int) async throws {
    let frame = try await generator.frame(forVersion: version)
    let ready = SourcePusher.ReadyFrame(pixels: frame.pixelBuffer)
    pusher.shelf.withLock { $0.ready[version] = ready }
    rendering[version] = nil
  }

  private func upcoming(after tick: Int) -> Set<Int> {
    let (ticksPerFrame, lastVersion) = pusher.shelf.withLock { ($0.ticksPerFrame, $0.lastVersion) }
    let nextShown = (tick + ticksPerFrame) / ticksPerFrame * ticksPerFrame
    let shown = (0..<Self.framesRenderedAhead).map { nextShown + $0 * ticksPerFrame }
    return Set(shown.map(timeline.version(atTick:))).subtracting([lastVersion].compactMap(\.self))
  }

  private func isReady(_ version: Int) -> Bool {
    pusher.shelf.withLock { $0.ready[version] != nil }
  }
}
