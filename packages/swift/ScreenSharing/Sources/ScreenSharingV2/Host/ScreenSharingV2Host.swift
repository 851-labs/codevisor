import Dispatch
import ScreenSharing

public final class ScreenSharingV2Host: ScreenSharingFrameSink, @unchecked Sendable {
  private struct Plan {
    let capture: ScreenSharingV2Capture
    let tiles: Set<Int>
    let isRefinement: Bool
  }

  public let metrics: ScreenSharingMetrics
  private let transport: any ScreenSharingMediaTransport
  private let encoder: any ScreenSharingTileEncoder
  private let layout: ScreenSharingV2TileLayout
  private let scheduler: any ScreenSharingV2Scheduler
  private let queue = DispatchQueue(label: "codevisor.screen-sharing.v2.host", qos: .userInteractive)
  private var slot: ScreenSharingV2CaptureSlot
  private var recovery = ScreenSharingV2Recovery()
  private var refinement = ScreenSharingV2Refinement()
  private var bitrate: ScreenSharingV2BitrateGovernor
  private var nextUpdate: UInt32 = 0
  private var retryScheduled = false
  private var failureRetryScheduled = false
  private var refinementWakeNs: Int64?
  private var deferredCapture = false
  private var busyTiles: Set<Int> = []
  private var stopped = false
  private var events: Task<Void, Never>?

  public convenience init(
    transport: any ScreenSharingMediaTransport, encoder: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics,
    initialBitrate: Int = ScreenSharingV2Profile.bitrateCeiling
  ) {
    self.init(
      transport: transport, encoder: encoder, metrics: metrics, initialBitrate: initialBitrate,
      scheduler: ScreenSharingV2SystemScheduler())
  }

  init(
    transport: any ScreenSharingMediaTransport, encoder: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics,
    initialBitrate: Int, scheduler: any ScreenSharingV2Scheduler
  ) {
    self.transport = transport
    self.encoder = encoder
    self.metrics = metrics
    self.scheduler = scheduler
    layout = encoder.layout
    slot = ScreenSharingV2CaptureSlot(tiles: encoder.layout.tiles)
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
      refinement.clear()
    }
    encoder.stop()
    transport.close()
    events?.cancel()
  }

  private func offer(_ capture: ScreenSharingV2Capture) {
    guard !stopped else { return }

    let reported = layout.tiles(touching: capture.frame.dirtyRects)
    let previous = (slot.waiting ?? slot.lastEncoded)?.frame.pixelBuffer
    let tiles = ScreenSharingV2TileComparer.changed(reported, of: layout, from: previous, to: capture.frame.pixelBuffer)
    metrics.increment("tilesUnchangedByPixels", by: reported.count - tiles.count)
    if slot.offer(capture, tiles: tiles) { metrics.increment("captureReplacedBeforeEncode") }
    pump()
  }

  private func pump() {
    guard !stopped else { return }
    guard let plan = nextPlan() else { return scheduleRefinement() }
    guard encoder.encodesWholeFrames ? busyTiles.isEmpty : busyTiles.isDisjoint(with: plan.tiles) else { return }

    let admission = transport.admission()
    guard admission.admit else { return deferEncode(admission) }

    adjustBitrate(admission)
    encode(plan)
  }

  private func nextPlan() -> Plan? {
    let refreshing = recovery.pendingTiles
    if let waiting = slot.waiting {
      let tiles = slot.waitingTiles.union(refreshing)
      if !tiles.isEmpty { return Plan(capture: waiting, tiles: tiles, isRefinement: false) }

      metrics.increment("captureUnchanged")
      slot.encoding(waiting)
    }
    guard let last = slot.lastEncoded else { return nil }
    guard refreshing.isEmpty else { return Plan(capture: last, tiles: refreshing, isRefinement: false) }
    guard let tile = refinement.next(atNs: scheduler.nowNs, excluding: busyTiles) else { return nil }

    return Plan(capture: last, tiles: [tile], isRefinement: true)
  }

  private func encode(_ plan: Plan) {
    slot.encoding(plan.capture)
    deferredCapture = false
    nextUpdate &+= 1
    let update = ScreenSharingTileUpdate(id: nextUpdate, tiles: plan.tiles, isRefinement: plan.isRefinement)
    let refreshes = recovery.takeRefreshes()
    note(update)
    let occupied = encoder.encodesWholeFrames ? layout.tiles : plan.tiles
    busyTiles.formUnion(occupied)
    do {
      try encoder.encode(plan.capture.request(update: update, refreshes: refreshes))
    } catch {
      metrics.increment("encodeErrors")
      metrics.label("lastEncodeError", error.localizedDescription)
      busyTiles.subtract(occupied)
      recovery.restore(refreshes)
      slot.requeue(tiles: plan.tiles)
    }
  }

  private func note(_ update: ScreenSharingTileUpdate) {
    let nowNs = scheduler.nowNs
    metrics.increment("tilesEncoded", by: update.tiles.count)
    if update.isRefinement {
      metrics.increment("refinementUpdates")
      refinement.refined(update.tiles, atNs: nowNs)
    } else {
      metrics.increment("tilesSkipped", by: layout.count - update.tiles.count)
      refinement.changed(update.tiles, atNs: nowNs)
    }
  }

  private func scheduleRefinement() {
    guard let dueNs = refinement.nextDueNs(excluding: busyTiles), refinementWakeNs.map({ dueNs < $0 }) ?? true else {
      return
    }

    refinementWakeNs = dueNs
    scheduler.run(afterNs: dueNs - scheduler.nowNs, on: queue) { [self] in
      guard refinementWakeNs == dueNs else { return }

      refinementWakeNs = nil
      pump()
    }
  }

  private func deferEncode(_ admission: ScreenSharingMediaAdmission) {
    if !deferredCapture { metrics.increment("admissionDeferrals") }
    deferredCapture = true
    guard !retryScheduled else { return }

    retryScheduled = true
    scheduler.run(afterNs: ScreenSharingV2AdmissionRetry.delayNs(after: admission), on: queue) { [self] in
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
    case .tile(let tile):
      send(tile)
      queue.async { [self] in finished(tile: tile.tile) }
    case .dropped(let tile, let refresh):
      queue.async { [self] in
        retry(refresh, tile: tile)
        finished(tile: tile)
      }
    case .unchanged(let tile):
      metrics.increment("encoderUnchangedTiles")
      queue.async { [self] in
        refinement.settled(tile)
        finished(tile: tile)
      }
    case .failed(let tile, let refresh, let message):
      metrics.label("lastEncodeError", message)
      queue.async { [self] in
        retry(refresh, tile: tile)
        busyTiles.remove(tile)
        retryAfterFailure()
      }
    }
  }

  private func finished(tile: Int) {
    busyTiles.remove(tile)
    pump()
  }

  private func retryAfterFailure() {
    guard !failureRetryScheduled else { return }

    failureRetryScheduled = true
    scheduler.run(afterNs: Int64(ScreenSharingV2Profile.frameIntervalUs) * 1_000, on: queue) { [self] in
      failureRetryScheduled = false
      pump()
    }
  }

  private func retry(_ refresh: ScreenSharingTileRefresh?, tile: Int) {
    slot.requeue(tiles: [tile])
    guard let refresh else { return }

    recovery.retry(refresh, tile: tile)
  }

  private func send(_ tile: ScreenSharingEncodedTile) {
    let meta = ScreenSharingV2HostTiming.meta(for: tile, layout: layout, sendingNs: ScreenSharingMetrics.nowNs)
    do {
      try transport.send(tile, meta: meta.data)
      metrics.increment("sentFrames")
      queue.async { [self] in recovery.sent(tile) }
    } catch {
      metrics.increment("sendErrors")
      metrics.label("lastSendError", "\(error)")
      queue.async { [self] in recovery.unsent(tile) }
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
