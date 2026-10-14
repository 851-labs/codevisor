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

@MainActor
public class ScreenSharingPeer {
  public let metrics: ScreenSharingMetrics
  public let controlChannel: ScreenSharingControlChannel
  public let clipboardChannel: ScreenSharingClipboardChannel
  public let cursorChannel: ScreenSharingCursorChannel
  public let audioChannel: ScreenSharingAudioChannel
  public let displayChannel: ScreenSharingDisplayChannel
  public let videoFormatChannel: ScreenSharingVideoFormatChannel
  public let simulatorChannel: ScreenSharingSimulatorChannel
  public let clipboardSharingChannel: ScreenSharingClipboardSharingChannel
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
    clipboardSharingChannel = staged.clipboardSharingChannel
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

  func handleRefresh(_ message: ScreenSharingVideoRefreshMessage) {}
  func refreshChannelBecameAvailable() {}
  func willClose() {}
  func didClose() {}

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

  public func statistics() async -> [String: String] {
    guard !closed else { return [:] }
    let values: [String: String]? = try? await transport.call { connection, done in
      connection.statistics { report in done(.success(ScreenSharingPeerStatistics.values(report))) }
    }
    return values ?? [:]
  }

  public func startRtcEventLog(path: String, maxSizeBytes: Int64) -> Bool {
    guard !closed else { return false }
    return transport.withDiagnosticConnection {
      $0.startRtcEventLog(withFilePath: path, maxSizeInBytes: maxSizeBytes)
    } ?? false
  }

  @discardableResult
  public func stopRtcEventLog() -> Bool {
    guard !closed else { return false }
    return transport.withDiagnosticConnection { $0.stopRtcEventLog() } != nil
  }

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
    clipboardSharingChannel.close()
    controlChannel.close()
    cancelGathering(CancellationError())
    transport.close(after: [
      videoRefresh, clipboardChannel, cursorChannel, audioChannel, displayChannel, videoFormatChannel,
      simulatorChannel, clipboardSharingChannel, controlChannel,
    ])
    didClose()
  }

  @discardableResult
  public func awaitClosed() async -> Int? {
    guard let count = await ownedWork.join() else { return nil }
    await transport.awaitTeardown()
    return count
  }

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
  let clipboardSharingChannel: ScreenSharingClipboardSharingChannel
  let videoRefresh: ScreenSharingDataChannel<ScreenSharingVideoRefreshMessage>

  typealias Role<Result> =
    @Sendable (RTCPeerConnectionFactory, RTCPeerConnection, ScreenSharingCodecFactory, ScreenSharingPeerTransport)
    throws -> Result

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

  private let factory: RTCPeerConnectionFactory
  private let connection: RTCPeerConnection

  private init(
    configuration: ScreenSharingVideoConfiguration, metrics: ScreenSharingMetrics,
    options: ScreenSharingPeerOptions, connectivity: ScreenSharingICEConfiguration?,
    frameDeliveryAudit: ScreenSharingFrameDeliveryAudit?, transport: ScreenSharingPeerTransport
  ) throws {
    self.metrics = metrics
    self.transport = transport
    ScreenSharingPeer.bootstrapTrials(publishingInto: metrics)
    codecFactory = ScreenSharingCodecFactory(
      metrics: metrics, useLowLatencyRateControl: options.useLowLatencyRateControl, codec: options.codec,
      fallbackCodecs: options.fallbackCodecs,
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
    rtcConfiguration.iceServers = connectivity?.servers.map(\.native) ?? []
    rtcConfiguration.iceTransportPolicy = connectivity?.relayOnly == true ? .relay : .all
    let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
    guard let connection = factory.peerConnection(with: rtcConfiguration, constraints: constraints, delegate: delegate)
    else {
      throw ScreenSharingError.unavailable("Cannot create native WebRTC peer.")
    }
    self.connection = connection
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
    clipboardSharingChannel = try ScreenSharingClipboardSharingChannel(
      connection: connection, id: 16, label: "codevisor.clipboard-sharing.v1",
      encode: { try $0.encoded() }, decode: ScreenSharingClipboardSharingMessage.decode)
  }
}
