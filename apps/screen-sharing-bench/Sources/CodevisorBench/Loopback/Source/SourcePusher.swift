import CoreVideo
import Dispatch
import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes
import Synchronization

final class SourcePusher: @unchecked Sendable {
  struct ReadyFrame: @unchecked Sendable {
    let pixels: CVPixelBuffer
  }

  struct Shelf {
    var ticksPerFrame = 1
    var scaler: FrameScaler?
    var lastVersion: Int?
    var ready: [Int: ReadyFrame] = [:]
    var produced: [BenchVersionEvent] = []
    var missed = 0

    func sized(_ frame: ReadyFrame) -> CVPixelBuffer? {
      guard let scaler else { return frame.pixels }

      return try? scaler.scaled(frame.pixels)
    }
  }

  static let tickNs = Int64(1_000_000_000 / BenchSceneTimeline.ticksPerSecond)

  let shelf = Mutex(Shelf())
  private let queue = DispatchQueue(label: "codevisor.bench.source", qos: .userInteractive)
  private let timer: any DispatchSourceTimer
  private let timeline: BenchSceneTimeline
  private let sink: any ScreenSharingFrameSink
  private var startNs: Int64 = 0
  private var ticks = 0
  private var finished: CheckedContinuation<Void, Never>?

  init(timeline: BenchSceneTimeline, sink: any ScreenSharingFrameSink) {
    self.timeline = timeline
    self.sink = sink
    timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
  }

  func run(ticks: Int, afterTick: @escaping @Sendable (Int) -> Void) async {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        finished = continuation
        self.ticks = ticks
        startNs = ScreenSharingMetrics.nowNs
        timer.setEventHandler { [self] in fire(afterTick) }
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(Self.tickNs)), leeway: .nanoseconds(0))
        timer.activate()
      }
    }
  }

  private func fire(_ afterTick: @Sendable (Int) -> Void) {
    let tick = Int((ScreenSharingMetrics.nowNs - startNs + Self.tickNs / 2) / Self.tickNs)
    guard tick < ticks else { return finish() }

    push(tick)
    afterTick(tick)
  }

  private func push(_ tick: Int) {
    shelf.withLock { shelf in
      guard tick.isMultiple(of: shelf.ticksPerFrame) else { return }

      let version = timeline.version(atTick: tick)
      guard version != shelf.lastVersion else { return }
      guard let frame = shelf.ready.removeValue(forKey: version), let pixels = shelf.sized(frame) else {
        return shelf.missed += 1
      }

      let timestampNs = ScreenSharingMetrics.nowNs
      sink.push(ScreenSharingVideoFrame(pixelBuffer: pixels, timestampNs: timestampNs))
      shelf.lastVersion = version
      shelf.produced.append(BenchVersionEvent(version: version, ns: timestampNs))
    }
  }

  private func finish() {
    timer.cancel()
    finished?.resume()
    finished = nil
  }
}
