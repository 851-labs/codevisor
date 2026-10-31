import Dispatch
import ScreenSharing

public final class ScreenSharingV2Host: ScreenSharingFrameSink, @unchecked Sendable {
  private static let admissionRetry = DispatchTimeInterval.milliseconds(1)

  public let metrics: ScreenSharingMetrics
  private let transport: any ScreenSharingMediaTransport
  private let encoder: any ScreenSharingTileEncoder
  private let queue = DispatchQueue(label: "codevisor.screen-sharing.v2.host", qos: .userInteractive)
  private var slot = ScreenSharingV2CaptureSlot()
  private var recovery = ScreenSharingV2Recovery()
  private var bitrate: ScreenSharingV2BitrateGovernor
  private var retryScheduled = false
  private var deferredCapture = false
  private var stopped = false
  private var events: Task<Void, Never>?

  public init(
    transport: any ScreenSharingMediaTransport, encoder: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics,
    initialBitrate: Int = ScreenSharingV2Profile.bitrateCeiling
  ) {
    self.transport = transport
    self.encoder = encoder
    self.metrics = metrics
    bitrate = ScreenSharingV2BitrateGovernor(initial: initialBitrate)
  }

  public func start() {
    encoder.onOutput { [weak self] output in self?.encoderOutput(output) }
    events = Task { [weak self, transport] in
      while let event = await transport.nextEvent() { self?.handle(event) }
    }
  }

  public func push(_ frame: ScreenSharingVideoFrame) {
    let capture = ScreenSharingV2Capture(frame: frame, capturedNs: ScreenSharingMetrics.nowNs)
    metrics.increment("captureFrames")
    queue.async { [self] in offer(capture) }
  }

  public func stop() {
    queue.sync {
      stopped = true
      slot.clear()
    }
    encoder.stop()
    transport.close()
    events?.cancel()
  }

  private func offer(_ capture: ScreenSharingV2Capture) {
    guard !stopped else { return }

    if slot.offer(capture) { metrics.increment("captureReplacedBeforeEncode") }
    pump()
  }

  private func pump() {
    guard !stopped, encoder.framesInFlight == 0 else { return }
    guard let capture = slot.next(refreshing: recovery.isPending) else { return }

    let admission = transport.admission()
    guard admission.admit else { return deferEncode() }

    adjustBitrate(admission)
    encode(capture)
  }

  private func encode(_ capture: ScreenSharingV2Capture) {
    slot.encoding(capture)
    deferredCapture = false
    let refreshes = recovery.takeRefreshes()
    do {
      try encoder.encode(capture.request(refreshes: refreshes))
    } catch {
      metrics.increment("encodeErrors")
      metrics.label("lastEncodeError", error.localizedDescription)
      recovery.restore(refreshes)
    }
  }

  private func deferEncode() {
    if !deferredCapture { metrics.increment("admissionDeferrals") }
    deferredCapture = true
    guard !retryScheduled else { return }

    retryScheduled = true
    queue.asyncAfter(deadline: .now() + Self.admissionRetry) { [self] in
      retryScheduled = false
      pump()
    }
  }

  private func adjustBitrate(_ admission: ScreenSharingMediaAdmission) {
    guard let target = bitrate.update(ceilingKbps: admission.encoderCeilingKbps, atNs: ScreenSharingMetrics.nowNs)
    else { return }

    do { try encoder.setBitrate(target) } catch { metrics.label("lastBitrateError", error.localizedDescription) }
  }

  private func encoderOutput(_ output: ScreenSharingTileEncoderOutput) {
    switch output {
    case .tile(let tile): send(tile)
    case .dropped(let tile, let refresh): queue.async { [self] in retry(refresh, tile: tile) }
    case .failed(let tile, let refresh, let message):
      metrics.label("lastEncodeError", message)
      queue.async { [self] in retry(refresh, tile: tile) }
    }
    queue.async { [self] in pump() }
  }

  private func retry(_ refresh: ScreenSharingTileRefresh?, tile: Int) {
    guard let refresh else { return }

    recovery.retry(refresh, tile: tile)
  }

  private func send(_ tile: ScreenSharingEncodedTile) {
    let meta = ScreenSharingV2HostTiming.meta(for: tile, sendingNs: ScreenSharingMetrics.nowNs)
    do {
      try transport.send(tile, meta: meta.data)
      metrics.increment("sentFrames")
      queue.async { [self] in recovery.sent(tile) }
    } catch {
      metrics.increment("sendErrors")
      metrics.label("lastSendError", "\(error)")
      queue.async { [self] in recovery.lost(tile: tile.tile) }
    }
  }

  private func handle(_ event: ScreenSharingMediaEvent) {
    switch event {
    case .frameAcked(let ack): observe(ack)
    case .frameLost(let stream, _): queue.async { [self] in lost(tile: Int(stream)) }
    case .ltrAcked(let stream, let token): queue.async { [self] in acknowledged(token, tile: Int(stream)) }
    case .frame, .frameSkipped: break
    }
  }

  private func observe(_ ack: ScreenSharingFrameAck) {
    metrics.increment("ackedFrames")
    metrics.observe("sendQueue", milliseconds: Double(ack.queuedUs) / 1000)
    metrics.observe("send", milliseconds: Double(ack.sendingUs) / 1000)
    metrics.observe("ackRoundTrip", milliseconds: Double(ack.ackedAfterUs) / 1000)
    queue.async { [self] in pump() }
  }

  private func lost(tile: Int) {
    metrics.increment("lostFrames")
    recovery.lost(tile: tile)
    pump()
  }

  private func acknowledged(_ token: UInt64, tile: Int) {
    guard recovery.acknowledged(token: token, tile: tile) else {
      metrics.increment("staleLTRAcknowledgements")
      return
    }

    metrics.increment("acknowledgedLTRTokens")
    encoder.acknowledge([token], tile: tile)
  }
}
