import Foundation
import QuartzCore
@preconcurrency import WebRTC
import ScreenSharing

public struct ScreenSharingDescription: Codable, Sendable {
  public let version: Int
  public let kind: String
  public let sdp: String
  public init(version: Int = 1, kind: String, sdp: String) {
    self.version = version; self.kind = kind; self.sdp = sdp
  }
}

/// What a sender and a receiver share: one `RTCPeerConnection` with the codec
/// factory installed, the three negotiated data channels, one-shot SDP
/// negotiation with complete ICE gathering, statistics, the RTC event log and
/// the close/await-closed boundary. Signaling is deliberately injected: the
/// probe can exchange files, the app uses authenticated machine channels.
///
/// `ScreenSharingSender` adds the video track and the host-side recovery;
/// `ScreenSharingReceiver` adds the renderer and the viewer-side recovery.
@MainActor
public class ScreenSharingPeer {
  public let metrics: ScreenSharingMetrics
  public let controlChannel: ScreenSharingControlChannel
  public let clipboardChannel: ScreenSharingClipboardChannel
  public var onConnectionChanged: ((String) -> Void)?
  let factory: RTCPeerConnectionFactory
  let codecFactory: ScreenSharingCodecFactory
  let connection: RTCPeerConnection
  let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>
  let ownedWork = ScreenSharingOwnedWork()
  private(set) var closed = false
  private let delegate: ScreenSharingPeerDelegate
  private var gathering: CheckedContinuation<ScreenSharingDescription, any Error>?
  private var gatheringTimeout: Task<Void, Never>?
  private var negotiating = false

  init(staged: ScreenSharingPeerStaging) {
    metrics = staged.metrics
    codecFactory = staged.codecFactory
    factory = staged.factory
    delegate = staged.delegate
    connection = staged.connection
    controlChannel = staged.controlChannel
    clipboardChannel = staged.clipboardChannel
    videoRefresh = staged.videoRefresh
    videoRefresh.onMessage = { [weak self] message in
      guard let self, !self.closed else { return }
      self.handleRefresh(message)
    }
    videoRefresh.onAvailabilityChanged = { [weak self] available in
      guard available, let self else { return }
      self.refreshChannelBecameAvailable()
    }
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
        self.remoteTrackArrived(track)
      }
    }
  }

  // MARK: Role hooks

  /// A message on the video-refresh channel; the sender answers keyframe requests, the receiver idle notices.
  func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {}
  /// The refresh channel opened: deferred requests and notices can go out now.
  func refreshChannelBecameAvailable() {}
  /// The remote video track was added (receiver only).
  func remoteTrackArrived(_ track: RTCVideoTrack) {}
  /// Role teardown, run before the shared teardown; `closed` is already true.
  func willClose() {}
  /// Role teardown after the connection closed.
  func didClose() {}

  // MARK: Negotiation

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

  // MARK: Diagnostics

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

  // MARK: Teardown

  public func close() {
    guard !closed else { return }
    closed = true
    willClose()
    videoRefresh.close()
    clipboardChannel.close()
    controlChannel.close()
    cancelGathering(CancellationError())
    connection.close()
    didClose()
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

/// Everything a peer needs before its role-specific members exist: the trials
/// pinned, the codec factory, the connection with its delegate, and the three
/// negotiated channels. A subclass builds this first (its own members may need
/// the factory), then hands it to `ScreenSharingPeer.init(staged:)`.
@MainActor
struct ScreenSharingPeerStaging {
  let metrics: ScreenSharingMetrics
  let codecFactory: ScreenSharingCodecFactory
  let factory: RTCPeerConnectionFactory
  let delegate: ScreenSharingPeerDelegate
  let connection: RTCPeerConnection
  let controlChannel: ScreenSharingControlChannel
  let clipboardChannel: ScreenSharingClipboardChannel
  let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>

  init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions, connectivity: ScreenSharingICEConfiguration?,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit? = nil
  ) throws {
    self.metrics = metrics
    // Process-wide WebRTC trials must exist before ANY RTC object. Real peers always bootstrap through the REAL
    // process boundary — there is deliberately no injection point here, because a fake initializer must never be able
    // to authorize a real RTC factory or publish a playout label that nothing installed.
    ScreenSharingPeer.bootstrapTrials(publishingInto: metrics)
    // Idle threshold and grace are diagnostic experiments; nil keeps the product defaults.
    codecFactory = ScreenSharingCodecFactory(
      metrics: metrics, useLowLatencyRateControl: options.useLowLatencyRateControl, codec: options.codec,
      disableLookAhead: options.disableLookAhead, maximumPendingFrames: options.maximumPendingFrames,
      staticCodecRate: options.staticCodecRate, completeEachFrame: options.completeEachFrame,
      prioritizeSpeed: options.prioritizeSpeed, keyframeIntervalSeconds: options.keyframeIntervalSeconds,
      sourceIdleThresholdNs: options.sourceIdleThresholdNs ?? ScreenSharingSourceIdleMonitor.defaultThresholdNs,
      frameDeliveryAudit: frameDeliveryAudit)
    factory = RTCPeerConnectionFactory(encoderFactory: codecFactory, decoderFactory: codecFactory)
    delegate = ScreenSharingPeerDelegate()
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
    controlChannel = try ScreenSharingControlChannel(
      connection: connection, id: 0, label: "codevisor.control.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingControlMessage.decode)
    clipboardChannel = try ScreenSharingClipboardChannel(
      connection: connection, id: 2, label: "codevisor.clipboard.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingClipboardMessage.decode)
    videoRefresh = try ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>(
      connection: connection, id: 4, label: "codevisor.video-refresh.v1",
      encode: { $0.encoded() }, decode: ScreenSharingVideoRefreshMessage.decode)
  }
}
