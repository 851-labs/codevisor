import QuartzCore
import ScreenSharing
import Synchronization

public final class ScreenSharingV2Viewer: @unchecked Sendable {
  private static let transportPollInterval = Duration.seconds(1)

  public let frames = ScreenSharingFrameMailbox()
  public let metrics: ScreenSharingMetrics
  private let transport: any ScreenSharingMediaTransport
  private let decoder: ScreenSharingV2Decoder
  private let gate = Mutex(ScreenSharingV2RecoveryGate())
  private let stopped = Atomic(false)
  private var tasks: [Task<Void, Never>] = []

  public init(transport: any ScreenSharingMediaTransport, metrics: ScreenSharingMetrics) {
    self.transport = transport
    self.metrics = metrics
    decoder = ScreenSharingV2Decoder(metrics: metrics)
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
    decoder.stop()
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
    guard let meta = try? ScreenSharingV2FrameMeta(frame.meta) else { return rejected("unreadableMeta") }
    guard admits(frame, meta: meta) else { return rejected("framesDroppedAwaitingRecovery") }

    do {
      try decoder.decode(frame, meta: meta, receivedNs: receivedNs) { [weak self] in self?.decoded($0) }
    } catch ScreenSharingV2DecoderError.sessionLost {
      metrics.increment("decoderSessionsLost")
      gate.withLock { $0.needKeyframe(stream: frame.stream) }
    } catch {
      metrics.label("lastDecodeError", error.localizedDescription)
      broke(frame.stream)
    }
  }

  private func admits(_ frame: ScreenSharingReceivedFrame, meta: ScreenSharingV2FrameMeta) -> Bool {
    gate.withLock { $0.admits(stream: frame.stream, isKeyFrame: frame.isKeyFrame, isRefresh: meta.isRefresh) }
  }

  private func rejected(_ counter: String) {
    metrics.increment(counter)
  }

  private func skipped(_ stream: UInt8) {
    metrics.increment("skippedFrames")
    gate.withLock { $0.broke(stream: stream) }
  }

  private func broke(_ stream: UInt8) {
    metrics.increment("decodeErrors")
    gate.withLock { $0.broke(stream: stream) }
  }

  private func decoded(_ result: ScreenSharingV2DecodeResult) {
    switch result {
    case .decoded(let context, let image, let decodedNs): present(image, context: context, decodedNs: decodedNs)
    case .failed(let context, let status):
      metrics.label("lastDecodeError", "VideoToolbox status \(status)")
      broke(context.frame.stream)
    }
  }

  private func present(_ image: CVPixelBuffer, context: ScreenSharingV2DecodeContext, decodedNs: Int64) {
    guard !stopped.load(ordering: .relaxed) else { return }

    metrics.increment("decodedFrames")
    metrics.observe("decode", milliseconds: Double(decodedNs - context.submittedNs) / 1_000_000)
    metrics.timeline.decoded(ScreenSharingV2ViewerTiming.decoded(context, decodedNs: decodedNs))
    frames.put(
      ScreenSharingVideoFrame(
        pixelBuffer: image, timestampNs: context.meta.sourceTimestampNs,
        rtpTimestamp: context.frame.frame, receivedAtSeconds: CACurrentMediaTime(),
        sourceTimestampNs: context.meta.sourceTimestampNs))
    guard let token = context.frame.ltrToken else { return }

    transport.acknowledge(ltrToken: token, stream: context.frame.stream)
  }

  private func pollTransport() async {
    while !Task.isCancelled {
      let networkUs = Int64(clamping: transport.roundTripUs / 2)
      metrics.timeline.observeTransport(networkUs: networkUs, jitterBufferUs: 0)
      try? await Task.sleep(for: Self.transportPollInterval)
    }
  }
}
