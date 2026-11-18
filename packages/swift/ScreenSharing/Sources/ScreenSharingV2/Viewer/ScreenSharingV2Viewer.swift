import CoreVideo
import QuartzCore
import ScreenSharing
import Synchronization
import VideoToolbox

public final class ScreenSharingV2Viewer: @unchecked Sendable {
  private static let transportPollInterval = Duration.seconds(1)

  public let frames: ScreenSharingFrameMailbox
  public let metrics: ScreenSharingMetrics
  private let transport: any ScreenSharingMediaTransport
  private let decoders: ScreenSharingV2Decoders
  private let composer = ScreenSharingV2FrameComposer()
  private let presentsTiles: Bool
  private let presentedComposite = Atomic<UInt64>(0)
  private let state = Mutex(ScreenSharingV2Picture())
  private let stopped = Atomic(false)
  private var tasks: [Task<Void, Never>] = []

  public init(
    transport: any ScreenSharingMediaTransport, metrics: ScreenSharingMetrics,
    frames: ScreenSharingFrameMailbox = ScreenSharingFrameMailbox(), presentsTiles: Bool = false
  ) {
    self.presentsTiles = presentsTiles
    self.transport = transport
    self.frames = frames
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
    case .frameAcked, .frameLost, .ltrAcked, .refreshRequested, .datagram: break
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
    guard state.withLock({ $0.follows(meta) }) else {
      metrics.increment("framesFromReplacedEncoder")
      return
    }
    guard let admission = admits(frame, meta: meta, receivedNs: receivedNs) else {
      missing(meta, tile: Int(frame.stream))
      metrics.increment("framesDroppedAwaitingRecovery")
      return
    }

    do {
      try decoders.decode(frame, meta: meta, receivedNs: receivedNs) { [weak self] in
        self?.decoded($0, admission: admission)
      }
    } catch ScreenSharingV2DecoderError.sessionLost {
      lostSession(frame.stream, admission: admission, atNs: receivedNs)
      missing(meta, tile: Int(frame.stream))
    } catch {
      metrics.label("lastDecodeError", error.localizedDescription)
      failed(frame.stream, admission: admission, atNs: receivedNs)
      missing(meta, tile: Int(frame.stream))
    }
  }

  private func admits(
    _ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta, receivedNs: Int64
  ) -> ScreenSharingV2RecoveryGate.Admission? {
    let (admission, stalled) = state.withLock { state in
      state.received(meta.update, tile: Int(frame.stream))
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
      return state.skipped(tile: Int(stream))
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

  private func lostSession(_ stream: UInt8, admission: ScreenSharingV2RecoveryGate.Admission, atNs nowNs: Int64) {
    metrics.increment("decoderSessionsLost")
    guard let refresh = state.withLock({ $0.gate.lostSession(stream: stream, admission, atNs: nowNs) }) else {
      metrics.increment("staleDecodeErrors")
      return
    }

    decoders.reset(stream: stream)
    request(refresh, stream: stream)
  }

  private func decoded(_ result: ScreenSharingV2DecodeResult, admission: ScreenSharingV2RecoveryGate.Admission) {
    switch result {
    case .decoded(let context, let image, let decodedNs):
      place(image, context: context, admission: admission, decodedNs: decodedNs)
    case .failed(let context, let status):
      metrics.label("lastDecodeError", "VideoToolbox status \(status)")
      if status == kVTInvalidSessionErr {
        lostSession(context.frame.stream, admission: admission, atNs: ScreenSharingMetrics.nowNs)
      } else {
        failed(context.frame.stream, admission: admission, atNs: ScreenSharingMetrics.nowNs)
      }
      missing(context.meta, tile: Int(context.frame.stream))
    }
  }

  private func place(
    _ image: CVPixelBuffer, context: ScreenSharingV2DecodeContext, admission: ScreenSharingV2RecoveryGate.Admission,
    decodedNs: Int64
  ) {
    guard !stopped.load(ordering: .relaxed) else { return }

    metrics.increment("decodedFrames")
    metrics.observe("decode", milliseconds: Double(decodedNs - context.submittedNs) / 1_000_000)
    let outcome = ScreenSharingV2UpdateAssembly.Outcome.decoded(context, image)
    let placement = state.withLock { state in
      if let stallNs = state.gate.decoded(stream: context.frame.stream, admission, atNs: decodedNs) {
        metrics.increment("recoveredTiles")
        metrics.observe("tileRecovery", milliseconds: Double(stallNs) / 1_000_000)
      }
      return state.resolved(outcome, of: context.meta, tile: Int(context.frame.stream))
    }
    if placement?.isLate == true { metrics.increment("lateTiles") }
    present(placement?.composite)
    guard let token = context.frame.ltrToken else { return }

    transport.acknowledge(ltrToken: token, stream: context.frame.stream)
  }

  private func missing(_ meta: ScreenSharingV2FrameMeta, tile: Int) {
    present(state.withLock { $0.resolved(.missing, of: meta, tile: tile) }?.composite)
  }

  private func present(_ composite: ScreenSharingV2Picture.Composite?) {
    guard let composite, !stopped.load(ordering: .relaxed) else { return }

    let startNs = ScreenSharingMetrics.nowNs
    let tiles = presentsTiles ? composite.snapshot.tiles : nil
    let image: CVPixelBuffer
    do {
      guard let composed = try tiles?.first?.pixelBuffer ?? composer.compose(composite.snapshot) else { return }

      image = composed
    } catch {
      metrics.label("lastComposeError", error.localizedDescription)
      return
    }
    let decodedNs = ScreenSharingMetrics.nowNs
    if tiles == nil { metrics.observe("compose", milliseconds: Double(decodedNs - startNs) / 1_000_000) }
    guard presentedComposite.max(composite.sequence) else {
      metrics.increment("supersededComposites")
      return
    }

    let timing = composite.group.flatMap { ScreenSharingV2ViewerTiming.composed($0, decodedNs: decodedNs) }
    if let timing { metrics.timeline.decoded(timing) }
    metrics.increment("presentedUpdates")
    let sourceTimestampNs = composite.group?.decoded.first?.meta.sourceTimestampNs
    let timestampNs = sourceTimestampNs ?? decodedNs
    let rtpTimestamp = composite.group?.update.id ?? 0
    let frame =
      tiles.flatMap {
        ScreenSharingVideoFrame(
          tiles: $0, size: composite.snapshot.size, timestampNs: timestampNs, rtpTimestamp: rtpTimestamp,
          receivedAtSeconds: CACurrentMediaTime(),
          sourceTimestampNs: timing?.sourceTimestampNs)
      }
      ?? ScreenSharingVideoFrame(
        pixelBuffer: image, timestampNs: timestampNs, rtpTimestamp: rtpTimestamp,
        receivedAtSeconds: CACurrentMediaTime(), sourceTimestampNs: timing?.sourceTimestampNs)
    frames.put(frame)
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
