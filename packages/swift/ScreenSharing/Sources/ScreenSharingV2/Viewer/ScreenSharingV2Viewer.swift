import CoreVideo
import QuartzCore
import ScreenSharing
import Synchronization
import VideoToolbox

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
    case .frameSkipped(let stream, _): skipped(stream, atNs: receivedNs)
    case .frameAcked, .frameLost, .ltrAcked, .refreshRequested: break
    }
  }

  private func receive(_ frame: ScreenSharingReceivedFrame, receivedNs: Int64) {
    metrics.increment("receivedFrames")
    metrics.observe("assemble", milliseconds: Double(frame.assemblingUs) / 1000)
    if frame.recovery != .none { metrics.increment("recovered.\(frame.recovery.rawValue)") }
    guard let meta = try? ScreenSharingV2FrameMeta(frame.meta), Int(frame.stream) < meta.layout.count else {
      metrics.increment("unreadableMeta")
      return
    }
    guard let admission = admits(frame, meta: meta, receivedNs: receivedNs) else {
      resolve(meta, tile: Int(frame.stream), .missing)
      metrics.increment("framesDroppedAwaitingRecovery")
      return
    }

    do {
      try decoders.decode(frame, meta: meta, receivedNs: receivedNs) { [weak self] in
        self?.decoded($0, admission: admission)
      }
    } catch ScreenSharingV2DecoderError.sessionLost {
      lostSession(frame.stream, atNs: receivedNs)
      resolve(meta, tile: Int(frame.stream), .missing)
    } catch {
      metrics.label("lastDecodeError", error.localizedDescription)
      failed(frame.stream, admission: admission, atNs: receivedNs)
      resolve(meta, tile: Int(frame.stream), .missing)
    }
  }

  private func admits(
    _ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64
  ) -> ScreenSharingV2RecoveryGate.Admission? {
    let (admission, stalled) = state.withLock { state in
      if state.canvas?.layout != meta.layout {
        state.canvas = ScreenSharingV2TileCanvas(layout: meta.layout)
        state.assembly.clear()
      }
      state.assembly.received(meta.update, tile: Int(frame.stream))
      let admission = state.gate.admits(stream: frame.stream, isKeyFrame: frame.isKeyFrame, isRefresh: meta.isRefresh)
      guard admission == nil else { return (admission, ScreenSharingTileRefresh?.none) }

      return (nil, state.gate.rejected(stream: frame.stream, atNs: receivedNs))
    }
    if let stalled {
      metrics.increment("stalledTiles")
      request(stalled, stream: frame.stream)
    }
    return admission
  }

  private func request(_ refresh: ScreenSharingTileRefresh, stream: UInt8) {
    metrics.increment(refresh == .keyframe ? "keyframeRequests" : "refreshRequests")
    transport.requestRefresh(stream: stream, keyframe: refresh == .keyframe)
  }

  private func skipped(_ stream: UInt8, atNs nowNs: Int64) {
    metrics.increment("skippedFrames")
    let composite = state.withLock { state in
      state.gate.skipped(stream: stream, atNs: nowNs)
      state.assembly.skipped(tile: Int(stream))
      return compose(&state)
    }
    present(composite)
  }

  private func failed(_ stream: UInt8, admission: ScreenSharingV2RecoveryGate.Admission, atNs nowNs: Int64) {
    metrics.increment("decodeErrors")
    let refresh = state.withLock { $0.gate.failed(stream: stream, admission, atNs: nowNs) }
    guard let refresh else {
      metrics.increment("staleDecodeErrors")
      return
    }

    request(refresh, stream: stream)
  }

  private func lostSession(_ stream: UInt8, atNs nowNs: Int64) {
    metrics.increment("decoderSessionsLost")
    decoders.reset(stream: stream)
    request(state.withLock { $0.gate.lostSession(stream: stream, atNs: nowNs) }, stream: stream)
  }

  private func decoded(_ result: ScreenSharingV2DecodeResult, admission: ScreenSharingV2RecoveryGate.Admission) {
    switch result {
    case .decoded(let context, let image, let decodedNs):
      place(image, context: context, admission: admission, decodedNs: decodedNs)
    case .failed(let context, let status):
      metrics.label("lastDecodeError", "VideoToolbox status \(status)")
      if status == kVTInvalidSessionErr {
        lostSession(context.frame.stream, atNs: ScreenSharingMetrics.nowNs)
      } else {
        failed(context.frame.stream, admission: admission, atNs: ScreenSharingMetrics.nowNs)
      }
      resolve(context.meta, tile: Int(context.frame.stream), .missing)
    }
  }

  private func place(
    _ image: CVPixelBuffer, context: ScreenSharingV2DecodeContext, admission: ScreenSharingV2RecoveryGate.Admission,
    decodedNs: Int64
  ) {
    guard !stopped.load(ordering: .relaxed) else { return }

    metrics.increment("decodedFrames")
    metrics.observe("decode", milliseconds: Double(decodedNs - context.submittedNs) / 1_000_000)
    let tile = Int(context.frame.stream)
    let composite = state.withLock { state in
      if let stallNs = state.gate.decoded(stream: context.frame.stream, admission, atNs: decodedNs) {
        metrics.increment("recoveredTiles")
        metrics.observe("tileRecovery", milliseconds: Double(stallNs) / 1_000_000)
      }
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
