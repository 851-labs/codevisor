import ScreenSharing
import ScreenSharingBench
import ScreenSharingBenchScenes
import ScreenSharingV2

@MainActor
struct LoopbackV2Cell {
  let scene: BenchScene
  let conditions: BenchNetworkConditions
  let settings: LoopbackSettings
  let repetition: Int

  func run() async throws -> LoopbackOutcome {
    let clockOffsetNs = BenchMachClock.continuousMinusAbsoluteNs()
    let relayOriginNs = BenchMachClock.nowNs()
    let relay = try LoopbackRelay(conditions: conditions, seed: settings.seed, originNs: relayOriginNs)
    defer { relay.close() }

    let peers = try await LoopbackV2Peers.connect(through: relay, configuration: configuration)
    let recording: LoopbackV2Recording
    do {
      recording = try await record(peers, through: relay)
    } catch {
      await peers.close()
      throw error
    }
    await peers.close()

    let measured = LoopbackMeasurement(
      scene: scene, conditions: conditions, settings: settings, repetition: repetition, clockOffsetNs: clockOffsetNs,
      relayOriginNs: relayOriginNs)
    return measured.outcome(recording, relay: relay)
  }

  private var configuration: ScreenSharingVideoConfiguration {
    get throws {
      try ScreenSharingV2Profile.captureConfiguration(
        width: settings.canvas.pixelWidth, height: settings.canvas.pixelHeight)
    }
  }

  private func record(_ peers: LoopbackV2Peers, through relay: LoopbackRelay) async throws -> LoopbackV2Recording {
    let source = try await LoopbackEnds.source(
      scene, settings: settings, sink: peers.host, metrics: peers.hostMetrics,
      pixelFormat: ScreenSharingV2Profile.capturePixelFormat)
    try await source.adapt(to: configuration)
    let mailbox = peers.viewer.frames
    let viewer = try LoopbackEnds.viewer(settings: settings, mailbox: mailbox, metrics: peers.viewerMetrics)
    let verifier = BarcodeVerifier(mailbox: mailbox, canvasWidth: settings.canvas.pixelWidth)
    let timeline = TimelineCollector(peers.viewerMetrics.timeline)

    peers.start()
    timeline.start()
    let startNs = ScreenSharingMetrics.nowNs
    let stop = {
      viewer.stop()
      return (records: timeline.stop(), barcodes: verifier.stop().versions)
    }
    do {
      try await source.run(for: .seconds(settings.durationSeconds))
      try await LoopbackEnds.drain(relay)
    } catch {
      _ = stop()
      throw error
    }
    let readings = stop()
    return LoopbackV2Recording(
      startNs: startNs, produced: await source.produced, records: readings.records, barcodes: readings.barcodes,
      hostCounters: peers.hostMetrics.counters(), viewerCounters: peers.viewerMetrics.counters(),
      hostLabels: peers.hostMetrics.snapshot().labels, viewerLabels: peers.viewerMetrics.snapshot().labels,
      hostMedia: V2MediaStatistics.dictionary(peers.hostTap.session.stats()),
      viewerMedia: V2MediaStatistics.dictionary(peers.viewerTap.session.stats()), mailboxDrops: mailbox.droppedFrames,
      taps: (peers.hostTap, peers.viewerTap))
  }
}
