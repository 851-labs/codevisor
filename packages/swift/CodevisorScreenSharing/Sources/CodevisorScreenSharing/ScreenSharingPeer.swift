import Foundation
import QuartzCore
@preconcurrency import WebRTC

public struct ScreenSharingDescription: Codable, Sendable {
  public let version: Int
  public let kind: String
  public let sdp: String
  public init(version: Int = 1, kind: String, sdp: String) {
    self.version = version; self.kind = kind; self.sdp = sdp
  }
}

/// Native media endpoint. Signaling is deliberately injected: the probe can
/// exchange files, the app uses authenticated machine channels.
@MainActor
public final class ScreenSharingPeer {
  public let metrics: ScreenSharingMetrics
  public let control: ScreenSharingControlChannel
  public let clipboard: ScreenSharingClipboardChannel
  public let mailbox = ScreenSharingFrameMailbox()
  /// Diagnostic: lets the bandwidth estimator's cap exceed the encoder's target, which stays capped at the
  /// configured bitrate through the sender's `maxBitrateBps`. nil keeps the product's single ceiling. How fast
  /// a keyframe may leave is the pacer's multiplier of the target (`WebRTC-Video-Pacing`), not this cap.
  private let transportCeilingBps: Int?
  public var onConnectionChanged: ((String) -> Void)?
  private let factory: RTCPeerConnectionFactory
  private let codecFactory: ScreenSharingCodecFactory
  private let delegate: ScreenSharingPeerDelegate
  private let renderer: ScreenSharingPeerRenderer
  private let connection: RTCPeerConnection
  private let source: RTCVideoSource
  private let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>
  private let refreshRequester: ScreenSharingRefreshRequester
  private let idleNotifier: ScreenSharingSourceIdleNotifier
  private let deliveryVerifier: ScreenSharingDeliveryVerifier
  private var refreshRateLimit = ScreenSharingRefreshRateLimit()
  public nonisolated let frameSender: ScreenSharingFrameSender
  private var gathering: CheckedContinuation<ScreenSharingDescription, any Error>?
  private var gatheringTimeout: Task<Void, Never>?
  private var remoteTrack: RTCVideoTrack?
  private var closed = false
  private var negotiating = false
  private let ownedWork = ScreenSharingOwnedWork()
  /// Receiver-only diagnostic frame-delivery audit (nil = disabled); closed with the peer.
  public let frameDeliveryAudit: ScreenSharingFrameDeliveryAudit?

  public init(
    sending: Bool, configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    connectivity: ScreenSharingICEConfiguration? = nil, useLowLatencyRateControl: Bool = true,
    codec: ScreenSharingVideoCodec = .h264, disableLookAhead: Bool = false, maximumPendingFrames: Int = 2,
    maintainSourceRate: Bool = false, staticCodecRate: Bool = false, completeEachFrame: Bool = false,
    prioritizeSpeed: Bool = false, keyframeIntervalSeconds: Int = 2, transportCeilingBps: Int? = nil,
    sourceIdleThresholdNs: Int64? = nil, deliveryGrace: Duration? = nil, deliveryGraceExtensions: Int? = nil,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit? = nil
  ) throws {
    self.metrics = metrics
    self.frameDeliveryAudit = frameDeliveryAudit
    if let transportCeilingBps {
      guard (configuration.bitrate...500_000_000).contains(transportCeilingBps) else {
        throw ScreenSharingError.invalid("Transport ceiling must be at least the video bitrate and at most 500 Mbps.")
      }
      metrics.label("transportCeiling", "\(transportCeilingBps) bps")
    }
    self.transportCeilingBps = transportCeilingBps
    // Process-wide WebRTC trials must exist before ANY RTC object. Real peers always bootstrap through the REAL
    // process boundary — there is deliberately no injection point here, because a fake initializer must never be able
    // to authorize a real RTC factory or publish a playout label that nothing installed.
    ScreenSharingPeer.bootstrapTrials(publishingInto: metrics)
    // Idle threshold and grace are diagnostic experiments; nil keeps the product defaults.
    let codecFactory = ScreenSharingCodecFactory(
      metrics: metrics, useLowLatencyRateControl: useLowLatencyRateControl, codec: codec,
      disableLookAhead: disableLookAhead, maximumPendingFrames: maximumPendingFrames, staticCodecRate: staticCodecRate,
      completeEachFrame: completeEachFrame, prioritizeSpeed: prioritizeSpeed,
      keyframeIntervalSeconds: keyframeIntervalSeconds,
      sourceIdleThresholdNs: sourceIdleThresholdNs ?? ScreenSharingSourceIdleMonitor.defaultThresholdNs,
      frameDeliveryAudit: frameDeliveryAudit)
    self.codecFactory = codecFactory
    factory = RTCPeerConnectionFactory(encoderFactory: codecFactory, decoderFactory: codecFactory)
    delegate = ScreenSharingPeerDelegate()
    renderer = ScreenSharingPeerRenderer(mailbox: mailbox, metrics: metrics, audit: frameDeliveryAudit)
    let rtcConfiguration = RTCConfiguration()
    rtcConfiguration.sdpSemantics = .unifiedPlan
    rtcConfiguration.bundlePolicy = .maxBundle
    rtcConfiguration.rtcpMuxPolicy = .require
    // Direct LAN is the default. Relay credentials arrive through authenticated
    // signaling and are never embedded in the client or persisted with a pane.
    rtcConfiguration.iceServers = connectivity?.servers.map(\.native) ?? []
    rtcConfiguration.iceTransportPolicy = connectivity?.relayOnly == true ? .relay : .all
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let connection = factory.peerConnection(with: rtcConfiguration, constraints: constraints, delegate: delegate)
    else {
      throw ScreenSharingError.unavailable("Cannot create native WebRTC peer.")
    }
    self.connection = connection
    control = try ScreenSharingControlChannel(
      connection: connection, id: 0, label: "codevisor.control.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingControlMessage.decode)
    clipboard = try ScreenSharingClipboardChannel(
      connection: connection, id: 2, label: "codevisor.clipboard.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingClipboardMessage.decode)
    let videoRefresh = try ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>(
      connection: connection, id: 4, label: "codevisor.video-refresh.v1",
      encode: { $0.encoded() }, decode: ScreenSharingVideoRefreshMessage.decode)
    self.videoRefresh = videoRefresh
    // Diagnostic: the first channel send after a verified shortfall decision.
    let requestSendMeasurement = ScreenSharingEncoderRefreshRequest()
    refreshRequester = ScreenSharingRefreshRequester(
      available: { [weak videoRefresh] in videoRefresh?.isAvailable == true },
      send: { [weak videoRefresh] in
        guard videoRefresh?.send(.keyframe) == true else { return false }
        metrics.increment("videoRefreshRequestsSent")
        if requestSendMeasurement.consume() {
          metrics.label("sourceIdleRequestSentAtNs", String(ScreenSharingMetrics.nowNs))
        }
        return true
      })
    source = factory.videoSource(forScreenCast: true)
    let frameSender = ScreenSharingFrameSender(
      source: source, metrics: metrics, idleMonitor: codecFactory.sourceIdleMonitor)
    self.frameSender = frameSender
    frameSender.configure(configuration)
    // Host: announce idle once per activity period so the viewer can verify
    // that the newest frame arrived despite loss that no later packet reveals.
    idleNotifier = ScreenSharingSourceIdleNotifier(
      monitor: codecFactory.sourceIdleMonitor,
      evaluated: { metrics.increment("sourceIdleEvaluations") },
      resubmit: { [monitor = codecFactory.sourceIdleMonitor] in
        metrics.increment("sourceIdleResubmissions")
        metrics.label(
          "sourceIdleState",
          monitor.resubmissionCount >= ScreenSharingSourceIdleMonitor.maximumQuickResubmissions
            ? "re-offering the latest capture at the slow bounded rate" : "re-offering the latest capture")
        frameSender.refreshLatest(reason: "reoffer")
      },
      notify: { [weak videoRefresh, monitor = codecFactory.sourceIdleMonitor] latestTimestampNs in
        guard videoRefresh?.send(.sourceIdle(latestTimestampNs: latestTimestampNs)) == true else {
          metrics.increment("sourceIdleNoticesDeferred")
          return false
        }
        let now = ScreenSharingMetrics.nowNs
        metrics.increment("sourceIdleNotices")
        metrics.label("sourceIdleLatestTimestampNs", String(latestTimestampNs))
        metrics.label("sourceIdleState", "latest capture announced")
        // Host clock only: last capture submission to notice.
        metrics.label("sourceIdleNoticeAtNs", String(now))
        if let submitted = monitor.latestSubmittedNs {
          metrics.observe("sourceIdleNoticeDelay", milliseconds: Double(now - submitted) / 1_000_000)
        }
        return true
      })
    // Viewer: a verified shortfall drives the existing keyframe recovery path
    // and keeps its target until the announced content is decoded.
    deliveryVerifier = ScreenSharingDeliveryVerifier(
      audit: codecFactory.deliveryAudit, grace: deliveryGrace ?? ScreenSharingDeliveryVerifier.defaultGrace,
      graceExtensions: deliveryGraceExtensions ?? ScreenSharingDeliveryVerifier.defaultGraceExtensions,
      refresh: { [refreshSignal = codecFactory.refreshSignal] in
        // Demand attribution: only a true result creates new recovery traffic.
        let now = String(ScreenSharingMetrics.nowNs)
        if refreshSignal.requestUnlessPending() {
          if metrics.increment("sourceIdleRecoveryInitiated") == 1 {
            metrics.label("sourceIdleRecoveryFirstInitiatedAtNs", now)
          }
          metrics.label("sourceIdleRecoveryLatestInitiatedAtNs", now)
        } else {
          if metrics.increment("sourceIdleRefreshAlreadyPending") == 1 {
            metrics.label("sourceIdleRefreshFirstAlreadyPendingAtNs", now)
          }
          metrics.label("sourceIdleRefreshLatestAlreadyPendingAtNs", now)
        }
      },
      report: { [audit = codecFactory.deliveryAudit] outcome in
        // Viewer clock only: notice received, refresh requested, target decoded.
        let now = ScreenSharingMetrics.nowNs
        func labelTargetDecoded() {
          if let met = audit.targetMetAtTimestampNs { metrics.label("sourceIdleTargetDecodedAtNs", String(met)) }
        }
        switch outcome {
        case .verified:
          metrics.increment("sourceIdleVerified")
          metrics.label("sourceIdleOutcome", "verified at notice")
          labelTargetDecoded()
        case .verifiedAfterGrace:
          metrics.increment("sourceIdleVerifiedAfterGrace")
          metrics.label("sourceIdleOutcome", "verified during grace")
          labelTargetDecoded()
        case .graceExtended:
          metrics.increment("sourceIdleGraceExtensions")
        case .refresh:
          metrics.increment("sourceIdleRefreshRequests")
          metrics.label("sourceIdleOutcome", "refresh requested")
          metrics.label("sourceIdleRefreshDecisionAtNs", String(now))
          requestSendMeasurement.request()
        case .recovered:
          metrics.increment("sourceIdleRecovered")
          metrics.label("sourceIdleOutcome", "recovered after refresh")
          labelTargetDecoded()
        case .retry: metrics.increment("sourceIdleRefreshRetries")
        case .retryExecuted:
          metrics.increment("sourceIdleRetriesExecuted")
          metrics.label("sourceIdleRetryLatestExecutedAtNs", String(now))
        }
      })
    if sending {
      let track = factory.videoTrack(with: source, trackId: "screen")
      // addTrack permits the remote viewer's offer to associate this sender
      // with its video m-line. An explicit unassociated addTransceiver stays
      // separate when answering, leaving ICE connected with no media sender.
      guard let sender = connection.add(track, streamIds: ["screen"]),
        let transceiver = connection.transceivers.first(where: { $0.sender.senderId == sender.senderId })
      else {
        throw ScreenSharingError.unavailable("Cannot create screen video sender.")
      }
      var directionError: NSError?
      transceiver.setDirection(.sendOnly, error: &directionError)
      if let directionError { connection.close(); throw directionError }
      let parameters = transceiver.sender.parameters
      parameters.degradationPreference = NSNumber(
        value: (maintainSourceRate
          ? RTCDegradationPreference.maintainFramerateAndResolution : .maintainResolution).rawValue)
      metrics.label("sourceAdaptation", maintainSourceRate ? "fixed format experiment" : "maintain resolution")
      for encoding in parameters.encodings {
        encoding.maxBitrateBps = NSNumber(value: configuration.bitrate)
        encoding.maxFramerate = NSNumber(value: configuration.framesPerSecond)
      }
      transceiver.sender.parameters = parameters
      connection.setBweMinBitrateBps(
        100_000, currentBitrateBps: NSNumber(value: configuration.bitrate),
        maxBitrateBps: NSNumber(value: transportCeilingBps ?? configuration.bitrate))
    }
    if !sending {
      let options = RTCRtpTransceiverInit()
      options.direction = .recvOnly
      guard connection.addTransceiver(of: .video, init: options) != nil else {
        throw ScreenSharingError.unavailable("Cannot create screen video receiver.")
      }
    }
    videoRefresh.onMessage = { [weak self] message in
      guard let self, !self.closed else { return }
      switch message {
      case .keyframe:
        guard sending else { return }
        self.metrics.increment("videoRefreshRequestsReceived")
        guard self.refreshRateLimit.allow(nowNs: ScreenSharingMetrics.nowNs) else {
          self.metrics.increment("videoRefreshRequestsThrottled")
          return
        }
        self.codecFactory.encoderRefreshRequest.request()
        self.frameSender.refreshLatest()
      case .sourceIdle(let latestTimestampNs):
        guard !sending else { return }
        self.metrics.increment("sourceIdleNoticesReceived")
        self.metrics.label("sourceIdleNoticeReceivedAtNs", String(ScreenSharingMetrics.nowNs))
        // Evidence of what the viewer held when the host announced idle.
        self.metrics.label(
          "sourceIdleNoticeDecodedTimestampNs",
          self.codecFactory.deliveryAudit.latestDecodedTimestampNs.map(String.init) ?? "none")
        self.metrics.label("sourceIdleNoticeTargetTimestampNs", String(latestTimestampNs))
        self.deliveryVerifier.noticed(latestTimestampNs: latestTimestampNs)
      }
    }
    if sending {
      frameSender.onActivity { [weak self] in Task { @MainActor in self?.idleNotifier.activate() } }
    }
    videoRefresh.onAvailabilityChanged = { [weak self] available in
      guard available, let self else { return }
      self.refreshRequester.wake()
      self.idleNotifier.flush()
    }
    codecFactory.refreshSignal.onChange { [weak self] event in
      // Recovery state trace (viewer clock): when keyframe recovery became
      // pending and when a decoded keyframe cleared it.
      let now = String(ScreenSharingMetrics.nowNs)
      if event.needed {
        if metrics.increment("refreshRecoveryPendingEvents") == 1 {
          metrics.label("refreshRecoveryFirstPendingAtNs", now)
        }
        metrics.label("refreshRecoveryLatestPendingAtNs", now)
      } else {
        if metrics.increment("refreshRecoveryClearedEvents") == 1 {
          metrics.label("refreshRecoveryFirstClearedAtNs", now)
        }
        metrics.label("refreshRecoveryLatestClearedAtNs", now)
      }
      Task { @MainActor in
        self?.refreshRequester.update(event)
        self?.deliveryVerifier.recoveryChanged(event)
      }
    }
    if !sending { codecFactory.refreshSignal.request() }
    delegate.onGathered = { [weak self] in Task { @MainActor in self?.finishGathering() } }
    delegate.onConnection = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        self.metrics.label("connection", state)
        self.onConnectionChanged?(state)
      }
    }
    delegate.onVideoTrack = { [weak self] track in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        self.remoteTrack?.remove(self.renderer)
        self.remoteTrack = track
        track.add(self.renderer)
      }
    }
  }

  /// Package-only fault injection for the standalone recovery probe. The
  /// decoder discards its VT state, then refuses deltas until a fresh keyframe.
  package func simulateDecoderLoss(
    afterFrames: Int, droppingRecoveryKeyframeFrom sender: ScreenSharingPeer? = nil,
    idlingCaptureFrom idleSender: ScreenSharingPeer? = nil
  ) {
    let dropCheck = sender?.codecFactory.encoderDropCheck
    let idleCapture = idleSender?.frameSender
    let idleMetrics = idleSender?.metrics
    codecFactory.recoveryCheck.arm(afterFrames: afterFrames) {
      dropCheck?.arm()
      idleCapture?.suspendCaptureDelivery()
      idleMetrics?.increment("captureDeliveryStoppedAtDecoderReset")
    }
    sender?.metrics.label("encoderRecoveryExperiment", "discard one forced output after decoder reset")
    idleMetrics?.label("sourceIdleExperiment", "capture delivery stops at decoder reset")
    metrics.label("decoderRecoveryExperiment", "discard reference state after \(afterFrames) input frames")
  }

  /// Returns SDP with gathered candidates. Caller must carry this over a
  /// trusted/authenticated signaling path; SDP fingerprints alone are not identity.
  public func makeDescription(offer: Bool) async throws -> ScreenSharingDescription {
    guard !closed, !negotiating else { throw ScreenSharingError.invalid("Peer is closed or already negotiating.") }
    negotiating = true
    defer { negotiating = false }
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    let rtc: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
      let complete: @Sendable (RTCSessionDescription?, (any Error)?) -> Void = { description, error in
        if let error {
          continuation.resume(throwing: error)
        } else if let description {
          continuation.resume(returning: description)
        } else {
          continuation.resume(throwing: ScreenSharingError.unavailable("No session description."))
        }
      }
      if offer {
        connection.offer(for: constraints, completionHandler: complete)
      } else {
        connection.answer(for: constraints, completionHandler: complete)
      }
    }
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.setLocalDescription(rtc) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        gathering = continuation
        if closed { cancelGathering(CancellationError()); return }
        if connection.iceGatheringState == .complete { finishGathering(); return }
        gatheringTimeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          self?.cancelGathering(ScreenSharingError.unavailable("ICE gathering timed out."))
        }
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.cancelGathering(CancellationError()) }
    }
  }

  public func accept(_ description: ScreenSharingDescription) async throws {
    guard !closed, description.version == 1, ["offer", "answer"].contains(description.kind),
      description.sdp.utf8.count <= 256 * 1024, description.sdp.contains("a=fingerprint:sha-256 ")
    else { throw ScreenSharingError.invalid("Unsupported or invalid screen-sharing description.") }
    let rtc = RTCSessionDescription(type: description.kind == "offer" ? .offer : .answer, sdp: description.sdp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.setRemoteDescription(rtc) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
  }

  public func statistics() async -> [String: String] {
    await withCheckedContinuation { continuation in
      connection.statistics { report in
        continuation.resume(returning: ScreenSharingPeerStatistics.values(report))
      }
    }
  }

  public func updateVideoConfiguration(_ configuration: ScreenSharingVideoConfiguration) {
    guard !closed else { return }
    frameSender.configure(configuration)
    for sender in connection.senders where sender.track?.kind == "video" {
      let parameters = sender.parameters
      for encoding in parameters.encodings {
        encoding.maxFramerate = NSNumber(value: configuration.framesPerSecond)
        encoding.maxBitrateBps = NSNumber(value: configuration.bitrate)
      }
      sender.parameters = parameters
    }
    metrics.label("captureSize", "\(configuration.width) × \(configuration.height)")
    metrics.label("captureFPS", String(configuration.framesPerSecond))
  }

  /// Diagnostic boundary for the receiver RTC event-log diagnostic: the shipped
  /// ObjC API, called synchronously by the caller; the peer schedules nothing.
  /// Returns the API's Bool (an accepted output, not a complete file); a closed
  /// peer never starts a log.
  public func startRtcEventLog(path: String, maxSizeBytes: Int64) -> Bool {
    guard !closed else { return false }
    return connection.startRtcEventLog(withFilePath: path, maxSizeInBytes: maxSizeBytes)
  }

  /// Stops a log started through `startRtcEventLog`; the caller stops exactly
  /// once before `close()`. Returns true only when the native stop API was
  /// invoked; a closed peer reports false so a no-op is never credited.
  @discardableResult
  public func stopRtcEventLog() -> Bool {
    guard !closed else { return false }
    connection.stopRtcEventLog()
    return true
  }

  public func close() {
    guard !closed else { return }
    closed = true
    codecFactory.refreshSignal.close()
    // Owned main-actor work is cancelled here and can be awaited by awaitClosed().
    ownedWork.close(with: [refreshRequester.close(), idleNotifier.close(), deliveryVerifier.close()].compactMap { $0 })
    codecFactory.sourceIdleMonitor.stop()
    videoRefresh.close()
    clipboard.close()
    control.close()
    frameSender.stop()
    cancelGathering(CancellationError())
    remoteTrack?.remove(renderer)
    renderer.stop()
    remoteTrack = nil
    connection.close()
    mailbox.clear()
    frameDeliveryAudit?.close()  // later decoder/VT/RTC/GPU/presented callbacks are counted as late, never recorded
  }

  /// Completion boundary for the peer's own cancelled tasks (requester, idle
  /// notifier, delivery verifier). The handles stay shared, so concurrent and
  /// repeated callers all wait for the same completions. Returns the number of
  /// owned tasks awaited, or nil when the peer has not been closed (the call
  /// then returns immediately and establishes nothing). WebRTC and
  /// VideoToolbox threads are not covered; their late callbacks are ignored by
  /// the closed signal, sender and renderer.
  @discardableResult
  public func awaitClosed() async -> Int? { await ownedWork.join() }

  private func finishGathering() {
    guard let description = connection.localDescription, let continuation = gathering else { return }
    gathering = nil
    gatheringTimeout?.cancel()
    gatheringTimeout = nil
    continuation.resume(
      returning: ScreenSharingDescription(
        version: 1, kind: description.type == .offer ? "offer" : "answer", sdp: description.sdp))
  }

  private func cancelGathering(_ error: any Error) {
    gatheringTimeout?.cancel()
    gatheringTimeout = nil
    let continuation = gathering
    gathering = nil
    continuation?.resume(throwing: error)
  }
}
