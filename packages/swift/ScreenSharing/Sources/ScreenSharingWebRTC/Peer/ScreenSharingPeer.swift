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

  init(native: RTCSessionDescription) {
    self.init(kind: native.type == .offer ? "offer" : "answer", sdp: native.sdp)
  }

  var native: RTCSessionDescription { RTCSessionDescription(type: kind == "offer" ? .offer : .answer, sdp: sdp) }
}

/// What a sender and a receiver share: one `RTCPeerConnection` with the codec
/// factory installed, the negotiated data channels, one-shot SDP
/// negotiation with complete ICE gathering, statistics, the RTC event log and
/// the close/await-closed boundary. Signaling is deliberately injected: the
/// probe can exchange files, the app uses authenticated machine channels.
///
/// `ScreenSharingSender` adds the video track and the host-side recovery;
/// `ScreenSharingReceiver` adds the renderer and the viewer-side recovery.
///
/// Threading: the peer's state, its role logic and every callback it makes live on the main
/// actor, but none of its WebRTC calls do. The connection, its factory and its media objects
/// belong to `transport`, confined to the transport's queue: construction (`init` is async),
/// negotiation, statistics, sender reconfiguration and teardown all run there, and each data
/// channel runs on its own queue. `close()` returns at once: the peer stops calling back
/// immediately, and the transport closes and releases the WebRTC objects in order behind it.
@MainActor
public class ScreenSharingPeer {
  public let metrics: ScreenSharingMetrics
  public let controlChannel: ScreenSharingControlChannel
  public let clipboardChannel: ScreenSharingClipboardChannel
  /// The host's pointer (851-2377); a peer without it never opens this channel.
  public let cursorChannel: ScreenSharingCursorChannel
  /// The host's sound (851-2379); a peer without it never opens this channel.
  public let audioChannel: ScreenSharingAudioChannel
  /// Dynamic Resolution on a virtual display (851-2376); a peer without it never opens this channel.
  public let displayChannel: ScreenSharingDisplayChannel
  /// HDR negotiation (851-2380).
  public let videoFormatChannel: ScreenSharingVideoFormatChannel
  /// An Apple simulator's input and device state; only `simulator:` streams use it.
  public let simulatorChannel: ScreenSharingSimulatorChannel
  public var onConnectionChanged: ((String) -> Void)?
  let codecFactory: ScreenSharingCodecFactory
  let transport: ScreenSharingPeerTransport
  let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>
  let ownedWork = ScreenSharingOwnedWork()
  let delegate: ScreenSharingPeerDelegate
  private(set) var closed = false
  private var gathering: CheckedContinuation<ScreenSharingDescription, any Error>?
  private var gatheringTimeout: Task<Void, Never>?
  private var negotiating = false

  init(staged: ScreenSharingPeerStaging) {
    metrics = staged.metrics
    codecFactory = staged.codecFactory
    transport = staged.transport
    delegate = staged.delegate
    controlChannel = staged.controlChannel
    clipboardChannel = staged.clipboardChannel
    cursorChannel = staged.cursorChannel
    audioChannel = staged.audioChannel
    displayChannel = staged.displayChannel
    videoFormatChannel = staged.videoFormatChannel
    simulatorChannel = staged.simulatorChannel
    videoRefresh = staged.videoRefresh
    videoRefresh.onMessage = { [weak self] message in
      guard let self, !self.closed else { return }
      self.handleRefresh(message)
    }
    videoRefresh.onAvailabilityChanged = { [weak self] available in
      guard available, let self else { return }
      self.refreshChannelBecameAvailable()
    }
    delegate.onGathered = { [weak self] in Task { @MainActor in self?.checkGathering() } }
    delegate.onConnection = { [weak self] state in
      Task { @MainActor in
        guard let self, !self.closed else { return }
        self.metrics.label("connection", state)
        self.onConnectionChanged?(state)
      }
    }
  }

  // MARK: Role hooks

  /// A message on the video-refresh channel; the sender answers keyframe requests, the receiver idle notices.
  func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {}
  /// The refresh channel opened: deferred requests and notices can go out now.
  func refreshChannelBecameAvailable() {}
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
    let local: ScreenSharingDescription = try await transport.call { connection, done in
      let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
      let complete: @Sendable (RTCSessionDescription?, (any Error)?) -> Void = { description, error in
        if let error {
          done(.failure(error))
        } else if let description {
          done(.success(ScreenSharingDescription(native: description)))
        } else {
          done(.failure(ScreenSharingError.unavailable("No session description.")))
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
    try await transport.call { connection, done in
      connection.setLocalDescription(local.native) { error in done(error.map { .failure($0) } ?? .success(())) }
    }
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        gathering = continuation
        if closed { cancelGathering(CancellationError()); return }
        gatheringTimeout = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(15)) } catch { return }
          self?.cancelGathering(ScreenSharingError.unavailable("ICE gathering timed out."))
        }
        // Gathering may already be complete (a re-answer); otherwise the delegate's completion checks again.
        checkGathering()
      }
    } onCancel: { [weak self] in
      Task { @MainActor in self?.cancelGathering(CancellationError()) }
    }
  }

  public func accept(_ description: ScreenSharingDescription) async throws {
    guard !closed, description.version == 1, ["offer", "answer"].contains(description.kind),
      description.sdp.utf8.count <= 256 * 1024, description.sdp.contains("a=fingerprint:sha-256 ")
    else { throw ScreenSharingError.invalid("Unsupported or invalid screen-sharing description.") }
    try await transport.call { connection, done in
      connection.setRemoteDescription(description.native) { error in
        done(error.map { .failure($0) } ?? .success(()))
      }
    }
  }

  /// The selected statistics; empty once the peer is closed.
  public func statistics() async -> [String: String] {
    guard !closed else { return [:] }
    let values: [String: String]? = try? await transport.call { connection, done in
      connection.statistics { report in done(.success(ScreenSharingPeerStatistics.values(report))) }
    }
    return values ?? [:]
  }

  // MARK: Diagnostics

  /// Diagnostic boundary for the receiver RTC event-log diagnostic: the shipped
  /// ObjC API, called synchronously by the caller (the rig times the call itself);
  /// the peer schedules nothing. Returns the API's Bool (an accepted output, not a
  /// complete file); a closed peer never starts a log. Product code never calls it.
  public func startRtcEventLog(path: String, maxSizeBytes: Int64) -> Bool {
    guard !closed else { return false }
    return transport.withDiagnosticConnection {
      $0.startRtcEventLog(withFilePath: path, maxSizeInBytes: maxSizeBytes)
    } ?? false
  }

  /// Stops a log started through `startRtcEventLog`; the caller stops exactly
  /// once before `close()`. Returns true only when the native stop API was
  /// invoked; a closed peer reports false so a no-op is never credited.
  @discardableResult
  public func stopRtcEventLog() -> Bool {
    guard !closed else { return false }
    return transport.withDiagnosticConnection { $0.stopRtcEventLog() } != nil
  }

  // MARK: Teardown

  /// Terminal and idempotent, and returns without waiting for WebRTC: no callback reaches the
  /// peer's owner afterwards, the channels publish their closing now, and the transport closes
  /// the connection once the channels' queues are done, then releases the factory, off main.
  public func close() {
    guard !closed else { return }
    closed = true
    willClose()
    videoRefresh.close()
    clipboardChannel.close()
    cursorChannel.close()
    audioChannel.close()
    displayChannel.close()
    videoFormatChannel.close()
    simulatorChannel.close()
    controlChannel.close()
    cancelGathering(CancellationError())
    transport.close(after: [
      videoRefresh, clipboardChannel, cursorChannel, audioChannel, displayChannel, videoFormatChannel,
      simulatorChannel, controlChannel,
    ])
    didClose()
  }

  /// Completion boundary for the peer's own cancelled tasks (requester, idle
  /// notifier, delivery verifier) and its WebRTC teardown: once it returns, the
  /// connection is closed and every WebRTC object the peer owned is released.
  /// The handles stay shared, so concurrent and repeated callers all wait for
  /// the same completions. Returns the number of owned tasks awaited, or nil when
  /// the peer has not been closed (the call then returns immediately and
  /// establishes nothing). VideoToolbox threads are not covered; their late
  /// callbacks are ignored by the closed signal, sender and renderer.
  @discardableResult
  public func awaitClosed() async -> Int? {
    guard let count = await ownedWork.join() else { return nil }
    await transport.awaitTeardown()
    return count
  }

  /// Resolves the description wait once gathering is complete; asks the transport, off main.
  private func checkGathering() {
    guard gathering != nil else { return }
    Task { [weak self, transport] in
      let gathered = await transport.inspect { connection -> ScreenSharingDescription? in
        guard let connection, connection.iceGatheringState == .complete, let local = connection.localDescription
        else { return nil }
        return ScreenSharingDescription(native: local)
      }
      guard let gathered else { return }
      self?.finishGathering(gathered)
    }
  }

  private func finishGathering(_ description: ScreenSharingDescription) {
    guard let continuation = gathering else { return }
    gathering = nil
    gatheringTimeout?.cancel()
    gatheringTimeout = nil
    continuation.resume(returning: description)
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
/// pinned, the codec factory, the connection with its delegate inside the
/// transport, and the negotiated channels. Built on the transport's queue by
/// `make`, then handed to the main actor once; after that its WebRTC objects are
/// only touched on their own queues.
struct ScreenSharingPeerStaging: @unchecked Sendable {
  let metrics: ScreenSharingMetrics
  let codecFactory: ScreenSharingCodecFactory
  let transport: ScreenSharingPeerTransport
  let delegate: ScreenSharingPeerDelegate
  let controlChannel: ScreenSharingControlChannel
  let clipboardChannel: ScreenSharingClipboardChannel
  let cursorChannel: ScreenSharingCursorChannel
  let audioChannel: ScreenSharingAudioChannel
  let displayChannel: ScreenSharingDisplayChannel
  let videoFormatChannel: ScreenSharingVideoFormatChannel
  let simulatorChannel: ScreenSharingSimulatorChannel
  let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>

  /// What the role adds on the transport's queue, with the factory, the connection, the codec
  /// factory and the transport (to retain what the connection needs kept alive).
  typealias Role<Result> =
    @Sendable (RTCPeerConnectionFactory, RTCPeerConnection, ScreenSharingCodecFactory, ScreenSharingPeerTransport)
    throws -> Result

  /// Builds the staging and runs `role`, all on a new transport's queue: nothing here waits for a
  /// WebRTC thread on the caller's.
  static func make<Result: Sendable>(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions, connectivity: ScreenSharingICEConfiguration?,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit? = nil, role: @escaping Role<Result>
  ) async throws -> (ScreenSharingPeerStaging, Result) {
    try await ScreenSharingPeerTransport.build { transport in
      let staged = try ScreenSharingPeerStaging(
        configuration: configuration, metrics: metrics, options: options, connectivity: connectivity,
        frameDeliveryAudit: frameDeliveryAudit, transport: transport)
      return (staged, try role(staged.factory, staged.connection, staged.codecFactory, transport))
    }
  }

  // Only for `make`'s role step; the transport owns both afterwards.
  private let factory: RTCPeerConnectionFactory
  private let connection: RTCPeerConnection

  private init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions, connectivity: ScreenSharingICEConfiguration?,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit?, transport: ScreenSharingPeerTransport
  ) throws {
    self.metrics = metrics
    self.transport = transport
    // Process-wide WebRTC trials must exist before ANY RTC object. Real peers always bootstrap through the REAL
    // process boundary — there is deliberately no injection point here, because a fake initializer must never be able
    // to authorize a real RTC factory or publish a playout label that nothing installed.
    ScreenSharingPeer.bootstrapTrials(publishingInto: metrics)
    // Idle threshold and grace are diagnostic experiments; nil keeps the product defaults.
    codecFactory = ScreenSharingCodecFactory(
      metrics: metrics, useLowLatencyRateControl: options.useLowLatencyRateControl, codec: options.codec,
      fallbackCodecs: options.fallbackCodecs,
      disableLookAhead: options.disableLookAhead, maximumPendingFrames: options.maximumPendingFrames,
      staticCodecRate: options.staticCodecRate, completeEachFrame: options.completeEachFrame,
      prioritizeSpeed: options.prioritizeSpeed, keyframeIntervalSeconds: options.keyframeIntervalSeconds,
      sourceIdleThresholdNs: options.sourceIdleThresholdNs ?? ScreenSharingSourceIdleMonitor.defaultThresholdNs,
      frameDeliveryAudit: frameDeliveryAudit)
    // One factory per peer: see `ScreenSharingPeerTransport` for why it can't be shared.
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
    // From here a failure closes and releases the connection on this queue.
    transport.adopt(factory: factory, connection: connection)
    controlChannel = try ScreenSharingControlChannel(
      connection: connection, id: 0, label: "codevisor.control.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingControlMessage.decode)
    clipboardChannel = try ScreenSharingClipboardChannel(
      connection: connection, id: 2, label: "codevisor.clipboard.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingClipboardMessage.decode)
    videoRefresh = try ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>(
      connection: connection, id: 4, label: "codevisor.video-refresh.v1",
      encode: { $0.encoded() }, decode: ScreenSharingVideoRefreshMessage.decode)
    // Negotiated like the others, before the offer: no renegotiation, and an older peer that
    // doesn't create stream 6 simply never answers on it.
    cursorChannel = try ScreenSharingCursorChannel(
      connection: connection, id: 6, label: "codevisor.cursor.v1", limits: .cursor,
      encode: { try $0.encoded() }, decode: ScreenSharingCursorMessage.decode)
    audioChannel = try ScreenSharingAudioChannel(
      connection: connection, id: 8, label: "codevisor.audio.v1", reliable: false,
      encode: { $0.encoded() }, decode: ScreenSharingAudioMessage.decode)
    displayChannel = try ScreenSharingDisplayChannel(
      connection: connection, id: 10, label: "codevisor.display.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingDisplayMessage.decode)
    videoFormatChannel = try ScreenSharingVideoFormatChannel(
      connection: connection, id: 12, label: "codevisor.video-format.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingVideoFormatMessage.decode)
    simulatorChannel = try ScreenSharingSimulatorChannel(
      connection: connection, id: 14, label: "codevisor.simulator.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingSimulatorMessage.decode)
  }
}
