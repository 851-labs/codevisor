import CoreVideo
import QuartzCore
import ScreenSharing
import Synchronization

public final class ScreenSharingV2Viewer: @unchecked Sendable {
  private struct State {
    var gate = ScreenSharingV2RecoveryGate()
    var assembly = ScreenSharingV2UpdateAssembly()
    var canvas: ScreenSharingV2TileCanvas?
    var nextComposite: UInt64 = 0
  }

  private struct Composite: @unchecked Sendable {
    let sequence: UInt64
    let snapshot: ScreenSharingV2TileCanvas.Snapshot
    let group: ScreenSharingV2UpdateAssembly.Group?
  }

  private static let transportPollInterval = Duration.seconds(1)

  public let frames = ScreenSharingFrameMailbox()
  public let metrics: ScreenSharingMetrics
  private let transport: any ScreenSharingMediaTransport
  private let decoders: ScreenSharingV2Decoders
  private let composer = ScreenSharingV2FrameComposer()
  private let presentedComposite = Atomic<UInt64>(0)
  private let state = Mutex(State())
  private let stopped = Atomic(false)
  private var tasks: [Task<Void, Never>] = []

  public init(transport: any ScreenSharingMediaTransport, metrics: ScreenSharingMetrics) {
    self.transport = transport
    self.metrics = metrics
    decoders = ScreenSharingV2Decoders(metrics: metrics)
  }

  public func start() {
    tasks = [
      Task { [weak self, transport] in
        while let event = await transport.nextEvent() { self?.handle(event, receivedNs: ScreenSharingMetrics.nowNs) }
      },
      Task { [weak self] in await self?.pollTransport() },
    ]
  }

  public func stop() {
    stopped.store(true, ordering: .relaxed)
    for task in tasks { task.cancel() }
    transport.close()
    decoders.stop()
    frames.clear()
  }

  private func handle(_ event: ScreenSharingMediaEvent, receivedNs: Int64) {
    switch event {
    case .frame(let frame): receive(frame, receivedNs: receivedNs)
    case .frameSkipped(let stream, _): skipped(stream)
    case .frameAcked, .frameLost, .ltrAcked: break
    }
  }

  private func receive(_ frame: ScreenSharingReceivedFrame, receivedNs: Int64) {
    metrics.increment("receivedFrames")
    metrics.observe("assemble", milliseconds: Double(frame.assemblingUs) / 1000)
    if frame.recovery != .none { metrics.increment("recovered.\(frame.recovery.rawValue)") }
    guard let meta = try? ScreenSharingV2FrameMeta(frame.meta), Int(frame.stream) < meta.layout.count else {
      return rejected("unreadableMeta")
    }
    guard admits(frame, meta: meta) else {
      resolve(meta, tile: Int(frame.stream), .missing)
      return rejected("framesDroppedAwaitingRecovery")
    }

    do {
      try decoders.decode(frame, meta: meta, receivedNs: receivedNs) { [weak self] in self?.decoded($0) }
    } catch ScreenSharingV2DecoderError.sessionLost {
      metrics.increment("decoderSessionsLost")
      state.withLock { $0.gate.needKeyframe(stream: frame.stream) }
      resolve(meta, tile: Int(frame.stream), .missing)
    } catch {
      metrics.label("lastDecodeError", error.localizedDescription)
      broke(frame.stream)
      resolve(meta, tile: Int(frame.stream), .missing)
    }
  }

  private func admits(_ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta) -> Bool {
    state.withLock { state in
      if state.canvas?.layout != meta.layout {
        state.canvas = ScreenSharingV2TileCanvas(layout: meta.layout)
        state.assembly.clear()
      }
      state.assembly.received(meta.update, tile: Int(frame.stream))
      return state.gate.admits(stream: frame.stream, isKeyFrame: frame.isKeyFrame, isRefresh: meta.isRefresh)
    }
  }

  private func rejected(_ counter: String) {
    metrics.increment(counter)
  }

  private func skipped(_ stream: UInt8) {
    metrics.increment("skippedFrames")
    let composite = state.withLock { state in
      state.gate.broke(stream: stream)
      state.assembly.skipped(tile: Int(stream))
      return compose(&state)
    }
    present(composite)
  }

  private func broke(_ stream: UInt8) {
    metrics.increment("decodeErrors")
    state.withLock { $0.gate.broke(stream: stream) }
  }

  private func decoded(_ result: ScreenSharingV2DecodeResult) {
    switch result {
    case .decoded(let context, let image, let decodedNs): place(image, context: context, decodedNs: decodedNs)
    case .failed(let context, let status):
      metrics.label("lastDecodeError", "VideoToolbox status \(status)")
      broke(context.frame.stream)
      resolve(context.meta, tile: Int(context.frame.stream), .missing)
    }
  }

  private func place(_ image: CVPixelBuffer, context: ScreenSharingV2DecodeContext, decodedNs: Int64) {
    guard !stopped.load(ordering: .relaxed) else { return }

    metrics.increment("decodedFrames")
    metrics.observe("decode", milliseconds: Double(decodedNs - context.submittedNs) / 1_000_000)
    let tile = Int(context.frame.stream)
    let composite = state.withLock { state in
      guard state.canvas?.layout == context.meta.layout else { return Composite?.none }

      let current = state.assembly.resolve(update: context.meta.update.id, tile: tile, .decoded(context, image))
      if !current {
        metrics.increment("lateTiles")
        state.canvas?.place(image, tile: tile)
      }
      return compose(&state, presentingLate: !current)
    }
    present(composite)
    guard let token = context.frame.ltrToken else { return }

    transport.acknowledge(ltrToken: token, stream: context.frame.stream)
  }

  private func resolve(_ meta: ScreenSharingV2FrameMeta, tile: Int, _ outcome: ScreenSharingV2UpdateAssembly.Outcome) {
    let composite = state.withLock { state in
      _ = state.assembly.resolve(update: meta.update.id, tile: tile, outcome)
      return compose(&state)
    }
    present(composite)
  }

  private func compose(_ state: inout State, presentingLate: Bool = false) -> Composite? {
    let ready = state.assembly.ready()
    for released in ready {
      for (tile, image) in released.images { state.canvas?.place(image, tile: tile) }
    }
    let group = ready.last { !$0.decoded.isEmpty }
    guard group != nil || presentingLate, let snapshot = state.canvas?.snapshot else { return nil }

    state.nextComposite += 1
    return Composite(sequence: state.nextComposite, snapshot: snapshot, group: group)
  }

  private func present(_ composite: Composite?) {
    guard let composite, !stopped.load(ordering: .relaxed) else { return }

    let startNs = ScreenSharingMetrics.nowNs
    let image: CVPixelBuffer
    do {
      guard let composed = try composer.compose(composite.snapshot) else { return }

      image = composed
    } catch {
      metrics.label("lastComposeError", error.localizedDescription)
      return
    }
    let decodedNs = ScreenSharingMetrics.nowNs
    metrics.observe("compose", milliseconds: Double(decodedNs - startNs) / 1_000_000)
    guard presentedComposite.max(composite.sequence) else {
      metrics.increment("supersededComposites")
      return
    }

    let timing = composite.group.flatMap { ScreenSharingV2ViewerTiming.composed($0, decodedNs: decodedNs) }
    if let timing { metrics.timeline.decoded(timing) }
    metrics.increment("presentedUpdates")
    let sourceTimestampNs = composite.group?.decoded.first?.meta.sourceTimestampNs
    frames.put(
      ScreenSharingVideoFrame(
        pixelBuffer: image, timestampNs: sourceTimestampNs ?? decodedNs,
        rtpTimestamp: composite.group?.update.id ?? 0, receivedAtSeconds: CACurrentMediaTime(),
        sourceTimestampNs: timing?.sourceTimestampNs))
  }

  private func pollTransport() async {
    while !Task.isCancelled {
      let networkUs = Int64(clamping: transport.roundTripUs / 2)
      metrics.timeline.observeTransport(networkUs: networkUs, jitterBufferUs: 0)
      try? await Task.sleep(for: Self.transportPollInterval)
    }
  }
}

extension Atomic where Value == UInt64 {
  fileprivate func max(_ candidate: UInt64) -> Bool {
    var current = load(ordering: .relaxed)
    while candidate > current {
      let (exchanged, original) = compareExchange(
        expected: current, desired: candidate, successOrdering: .relaxed, failureOrdering: .relaxed)
      if exchanged { return true }
      current = original
    }
    return false
  }
}
