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
  private var refinement: ScreenSharingV2Refinement
  private let policyOverride: ScreenSharingV2RefinementPolicy?
  private var bitrate: ScreenSharingV2BitrateGovernor
  private var networkFeedbackNs: Int64?
  private var nextUpdate: UInt32 = 0
  private var retryScheduled = false
  private var failureRetryScheduled = false
  private var refinementWakeNs: Int64?
  private var refreshPhase: ScreenSharingV2RefreshPhase
  private var deferredCapture = false
  private var inFlight: [Int: Int] = [:]
  private static let pipelinedChanges = 2
  private static let networkFeedbackIntervalNs: Int64 = 250_000_000
  private var stopped = false
  private var events: Task<Void, Never>?

  public convenience init(
    transport: any ScreenSharingMediaTransport, encoder: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics,
    initialBitrate: Int = ScreenSharingV2Profile.bitrateCeiling,
    refinement: ScreenSharingV2RefinementPolicy? = nil
  ) {
    self.init(
      transport: transport, encoder: encoder, metrics: metrics, initialBitrate: initialBitrate,
      scheduler: ScreenSharingV2SystemScheduler(), refinement: refinement)
  }

  init(
    transport: any ScreenSharingMediaTransport, encoder: any ScreenSharingTileEncoder, metrics: ScreenSharingMetrics,
    initialBitrate: Int, scheduler: any ScreenSharingV2Scheduler,
    refinement policy: ScreenSharingV2RefinementPolicy? = nil,
    refreshPhase: ScreenSharingV2RefreshPhase = ScreenSharingV2RefreshPhase()
  ) {
    self.transport = transport
    self.encoder = encoder
    self.metrics = metrics
    self.scheduler = scheduler
    layout = encoder.layout
    slot = ScreenSharingV2CaptureSlot(tiles: encoder.layout.tiles)
    bitrate = ScreenSharingV2BitrateGovernor(initial: initialBitrate)
    policyOverride = policy
    refinement = ScreenSharingV2Refinement(passes: (policy ?? encoder.refinementPolicy).passes)
    self.refreshPhase = refreshPhase
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

    metrics.observe("captureQueueWait", milliseconds: Double(ScreenSharingMetrics.nowNs - capture.capturedNs) / 1e6)
    refreshPhase.observe(frameAtNs: capture.frame.timestampNs)
    refinementWakeNs = nil
    let reported = layout.tiles(touching: capture.frame.dirtyRects)
    let previous = (slot.waiting ?? slot.lastEncoded)?.frame.pixelBuffer
    let candidates = reported.subtracting(slot.waitingTiles)
    let comparedNs = ScreenSharingMetrics.nowNs
    let tiles = ScreenSharingV2TileComparer.changed(
      candidates, of: layout, from: previous, to: capture.frame.pixelBuffer)
    metrics.observe("tileCompare", milliseconds: Double(ScreenSharingMetrics.nowNs - comparedNs) / 1e6)
    metrics.increment("tilesUnchangedByPixels", by: candidates.count - tiles.count)
    if slot.offer(capture, tiles: tiles) { metrics.increment("captureReplacedBeforeEncode") }
    pump()
  }

  private func pump() {
    guard !stopped else { return }
    guard let plan = nextPlan() else { return scheduleRefinement() }
    guard admits(plan) else { return }

    let admission = transport.admission()
    guard admission.admit else { return deferEncode(admission) }

    adjustBitrate(admission)
    observeNetwork(admission)
    encode(plan)
  }

  private var busyTiles: Set<Int> { Set(inFlight.keys) }

  private func admits(_ plan: Plan) -> Bool {
    if plan.isRefinement { return busyTiles.isDisjoint(with: plan.tiles) }

    let depth = layout.count > 1 ? Self.pipelinedChanges : 1
    return plan.tiles.allSatisfy { inFlight[$0, default: 0] < depth }
  }

  private func release(_ tile: Int) {
    guard let count = inFlight[tile] else { return }

    inFlight[tile] = count > 1 ? count - 1 : nil
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
    guard let tile = refinement.next(atNs: scheduler.nowNs, excluding: busyTiles, aligned: refreshPhase.aligned)
    else { return nil }

    return Plan(capture: last, tiles: [tile], isRefinement: true)
  }

  private func encode(_ plan: Plan) {
    slot.encoding(plan.capture)
    deferredCapture = false
    nextUpdate &+= 1
    let update = ScreenSharingTileUpdate(id: nextUpdate, tiles: plan.tiles, isRefinement: plan.isRefinement)
    let refreshes = recovery.takeRefreshes()
    note(update)
    for tile in plan.tiles { inFlight[tile, default: 0] += 1 }
    do {
      try encoder.encode(plan.capture.request(update: update, refreshes: refreshes))
    } catch {
      metrics.increment("encodeErrors")
      metrics.label("lastEncodeError", error.localizedDescription)
      for tile in plan.tiles { release(tile) }
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
      refinement.changed(update.tiles, by: update.id, atNs: nowNs)
    }
  }

  private func scheduleRefinement() {
    guard let dueNs = refinement.nextDueNs(excluding: busyTiles, aligned: refreshPhase.aligned),
      refinementWakeNs.map({ dueNs < $0 }) ?? true
    else { return }

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

  private func observeNetwork(_ admission: ScreenSharingMediaAdmission) {
    let nowNs = scheduler.nowNs
    if let networkFeedbackNs, nowNs - networkFeedbackNs < Self.networkFeedbackIntervalNs { return }

    networkFeedbackNs = nowNs
    encoder.observeNetwork(
      ScreenSharingTileNetworkFeedback(
        packetErrorRate: transport.lossRate, roundTripDelayMs: Double(transport.roundTripUs) / 1000,
        transmissionBitsPerSecond: Int(clamping: admission.estimateKbps * 1000)))
  }

  private func encoderOutput(_ output: ScreenSharingTileEncoderOutput) {
    switch output {
    case .tile(let tile):
      send(tile)
      queue.async { [self] in
        if (policyOverride ?? encoder.refinementPolicy).converged(tile) {
          metrics.increment("refinementsConverged")
          refinement.settled(tile.tile, by: tile.update.id)
        }
        finished(tile: tile.tile)
      }
    case .dropped(let tile, let refresh):
      queue.async { [self] in
        retry(refresh, tile: tile)
        finished(tile: tile)
      }
    case .unchanged(let tile, let update):
      metrics.increment("encoderUnchangedTiles")
      queue.async { [self] in
        refinement.settled(tile, by: update)
        finished(tile: tile)
      }
    case .failed(let tile, let refresh, let message):
      metrics.label("lastEncodeError", message)
      queue.async { [self] in
        retry(refresh, tile: tile)
        release(tile)
        retryAfterFailure()
      }
    }
  }

  private func finished(tile: Int) {
    release(tile)
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
    if let stream = event.stream, !layout.tiles.contains(Int(stream)) {
      metrics.increment("eventsForUnknownTiles")
      return
    }
    switch event {
    case .frameAcked(let ack): observe(ack)
    case .frameLost(let stream, _): queue.async { [self] in lost(tile: Int(stream)) }
    case .ltrAcked(let stream, let token): queue.async { [self] in acknowledged(token, tile: Int(stream)) }
    case .refreshRequested(let stream, let keyframe):
      queue.async { [self] in requested(keyframe: keyframe, tile: Int(stream)) }
    case .frame, .frameSkipped, .datagram: break
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

  private func requested(keyframe: Bool, tile: Int) {
    metrics.increment(keyframe ? "requestedKeyframes" : "requestedRefreshes")
    recovery.requested(keyframe: keyframe, tile: tile)
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
