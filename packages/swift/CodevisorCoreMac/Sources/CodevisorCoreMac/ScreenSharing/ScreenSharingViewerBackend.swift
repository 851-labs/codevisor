import CodevisorClient
import ScreenSharing
import ScreenSharingWebRTC
import ComposableArchitecture
import Foundation

@CasePathable
public enum ScreenSharingViewerEvent: Equatable, Sendable {
  case elsewhere(ScreenSharingViewerEndpoint?)
  case ended(String)
  case opened(ScreenSharingViewerEndpoint)
  case ready
  case reconnecting
  case hostNotice(String?)
}

@DependencyClient
public struct ScreenSharingViewerBackend: Sendable {
  public var connect: @Sendable (_ displayId: String) async -> AsyncStream<ScreenSharingViewerEvent> = { _ in
    .finished
  }
  public var discover: @Sendable () async throws -> [ServerScreenSharingDisplay]
  public var claim: @Sendable () async -> Void = {}
  public var setVisible: @Sendable (_ visible: Bool) async -> Void = { _ in }
  public var retire: @Sendable () async -> Void = {}
  public var liveStreams: @Sendable () async -> AsyncStream<Void> = { .finished }
}

public struct ScreenSharingTunnelMedia: Sendable {
  public let endpointId: String
  public let flowId: Int
  public let localPort: UInt16
  public let close: @Sendable () -> Void

  public init(endpointId: String, flowId: Int, localPort: UInt16, close: @escaping @Sendable () -> Void) {
    self.endpointId = endpointId
    self.flowId = flowId
    self.localPort = localPort
    self.close = close
  }
}

extension ScreenSharingViewerBackend: TestDependencyKey {
  public static var testValue: Self { Self() }
}

extension ScreenSharingViewerBackend {
  public typealias TunnelMediaProvider = @MainActor () async -> ScreenSharingTunnelMedia?

  @MainActor
  public static func native(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID, machineId: String? = nil,
    role: ScreenSharingViewerRole = .tab, tunnelMedia: TunnelMediaProvider? = nil
  ) -> Self {
    native(
      client: client, workspaceId: workspaceId, paneId: paneId, machineId: machineId, role: role,
      tunnelMedia: tunnelMedia,
      sleep: { try await Task.sleep(for: $0) },
      makeSession: { try await ScreenSharingReceiver.process(connectivity: $0) },
      makeSurface: { session in
        try ScreenSharingVideoSurface(mailbox: session.frames, metrics: session.metrics)
      },
      vncOpen: { displayId in
        let socket = try client.screenSharingVNCSocket(displayId: displayId)
        return try await VNCConnection.open(transport: RFBWebSocketTransport(socket: socket), password: nil)
      })
  }

  typealias NativeVNCOpen = @Sendable (String) async throws -> (client: RFBClient, outcome: RFBHandshake.Outcome)

  @MainActor
  static func native(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID, machineId: String? = nil,
    role: ScreenSharingViewerRole = .tab, tunnelMedia: TunnelMediaProvider? = nil,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    makeSession:
      @escaping @MainActor (ServerScreenSharingConnectivity?) async throws -> any NativeScreenSharingMediaSession,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface,
    vncOpen: @escaping NativeVNCOpen = { _ in throw RFBError.transport("This machine has no VNC display.") },
    target: String? = nil,
    heartbeatInterval: Duration = .seconds(8)
  ) -> Self {
    let sharesStream = machineId != nil
    let runner = NativeScreenSharingViewerRunner(
      client: client, workspaceId: workspaceId, paneId: paneId, sleep: sleep, makeSession: makeSession,
      makeSurface: makeSurface, vncOpen: vncOpen, target: target, tunnelMedia: tunnelMedia,
      heartbeatInterval: heartbeatInterval, sound: !sharesStream)
    guard let machineId else {
      return Self(
        connect: { display in await runner.connect(display) }, discover: { try await runner.discover() }, claim: {},
        setVisible: { _ in }, retire: {}, liveStreams: { .finished })
    }
    let share = ScreenSharingViewerRegistry.shared.share(
      machineId: machineId, paneId: paneId, role: role, runner: runner)
    return Self(
      connect: { display in await share.connect(display) }, discover: { try await runner.discover() },
      claim: { await share.claim() }, setVisible: { visible in await share.setVisible(visible) },
      retire: { await share.retire() }, liveStreams: { await share.liveStreams() })
  }
}

@MainActor
private final class NativeScreenSharingViewerRunner: ScreenSharingViewerConnecting {
  private let client: any CodevisorServerClienting
  private let workspaceId: UUID
  private let paneId: UUID
  private let sleep: @Sendable (Duration) async throws -> Void
  private let makeSession:
    @MainActor (ServerScreenSharingConnectivity?) async throws -> any NativeScreenSharingMediaSession
  private let makeSurface: @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface
  private let vncOpen: ScreenSharingViewerBackend.NativeVNCOpen
  private var previous: Task<Void, Never>?
  private var provider: String?
  private var controlLease = false
  private var vncRunners: [String: VNCScreenSharingViewerRunner] = [:]
  private let target: String?
  private let heartbeatInterval: Duration
  private let tunnelMedia: ScreenSharingViewerBackend.TunnelMediaProvider?
  private let sound: Bool

  init(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    makeSession:
      @escaping @MainActor (ServerScreenSharingConnectivity?) async throws -> any NativeScreenSharingMediaSession,
    makeSurface: @escaping @MainActor (any ScreenSharingViewingSession) throws -> any ScreenSharingViewerSurface,
    vncOpen: @escaping ScreenSharingViewerBackend.NativeVNCOpen,
    target: String? = nil,
    tunnelMedia: ScreenSharingViewerBackend.TunnelMediaProvider? = nil,
    heartbeatInterval: Duration = .seconds(8),
    sound: Bool = true
  ) {
    self.sound = sound
    self.target = target
    self.heartbeatInterval = heartbeatInterval
    self.tunnelMedia = tunnelMedia
    self.client = client
    self.workspaceId = workspaceId
    self.paneId = paneId
    self.sleep = sleep
    self.makeSession = makeSession
    self.makeSurface = makeSurface
    self.vncOpen = vncOpen
  }

  func discover() async throws -> [ServerScreenSharingDisplay] {
    await previous?.value
    try Task.checkCancellation()
    let capabilities = request(.capabilities, viewerId: UUID())
    let reply = try await ScreenSharingTransientRetry.run(sleep: sleep) { [client] in
      try await client.screenSharing(capabilities)
    }
    guard reply.version == 1, ["available", "busy"].contains(reply.status) else {
      throw ViewerError(reply.message ?? "Screen Sharing is unavailable on this Mac.")
    }
    provider = reply.provider
    controlLease = reply.controlLease == true
    return reply.displays
  }

  func idle() async { await previous?.value }

  func connect(_ display: String) -> AsyncStream<ScreenSharingViewerEvent> {
    if provider == "vnc" || display.hasPrefix("vnc:") { return vncRunner(for: display).connect() }
    return AsyncStream { continuation in
      let pending = previous
      let run = Task { @MainActor [self] in
        await pending?.value
        if !Task.isCancelled {
          await self.run(display: display) { continuation.yield($0) }
        }
        continuation.finish()
      }
      previous = run
      continuation.onTermination = { _ in run.cancel() }
    }
  }

  private func vncRunner(for display: String) -> VNCScreenSharingViewerRunner {
    if let runner = vncRunners[display] { return runner }
    let open = vncOpen
    let runner = VNCScreenSharingViewerRunner(
      displayId: display, open: { try await open(display) },
      arbitratedByServer: { [weak self] in self?.controlLease ?? false },
      setDesktopScale: { [client, weak self] scale in
        guard let request = self?.request(.setScale, viewerId: UUID(), displayId: display) else { return }
        var scaled = request
        scaled.scale = scale
        _ = try? await client.screenSharing(scaled)
      },
      makeSurface: makeSurface)
    vncRunners[display] = runner
    return runner
  }

  private enum Outcome { case lost, ended(String), cancelled }

  @MainActor
  private final class Attempt {
    var endpoint: ScreenSharingViewerEndpoint?
    var tunnelMedia: ScreenSharingTunnelMedia?
    var body: Task<Outcome, Never>?
    var ready = false
    var started = false
    var outcome: Outcome?
    var transportEnded = false
  }

  private func run(display: String, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void) async {
    let viewerId = UUID()
    var restarts = 0
    var started = false
    var message: String?
    attempts: while !Task.isCancelled {
      let (outcome, attemptStarted) = await attempt(
        viewerId: viewerId, display: display, restarts: restarts, emit: emit)
      started = started || attemptStarted
      switch outcome {
      case .lost:
        restarts += 1
        emit(.reconnecting)
      case .ended(let reason):
        message = reason
        break attempts
      case .cancelled:
        break attempts
      }
    }
    if let message { emit(.ended(message)) }
    if started {
      let stop = request(.stop, viewerId: viewerId)
      let client = client
      await Task { _ = try? await client.screenSharing(stop) }.value
    }
  }

  private func attempt(
    viewerId: UUID, display: String, restarts: Int, emit: @escaping @Sendable (ScreenSharingViewerEvent) -> Void
  ) async -> (Outcome, started: Bool) {
    let attempt = Attempt()
    let body = Task { @MainActor [self] () -> Outcome in
      do {
        let capabilitiesRequest = request(.capabilities, viewerId: viewerId)
        let capabilities = try await ScreenSharingTransientRetry.run(sleep: sleep) { [client] in
          try await client.screenSharing(capabilitiesRequest)
        }
        try Task.checkCancellation()
        guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
          return .ended(capabilities.message ?? "Screen Sharing is unavailable on this Mac.")
        }
        let session = try await makeSession(capabilities.connectivity)
        if Task.isCancelled {
          session.close()
          throw CancellationError()
        }
        let endpoint = ScreenSharingViewerEndpoint(session: session, surface: try makeSurface(session), sound: sound)
        endpoint.dropsInjectedInput = ScreenSharingDisplayIdentity.isOnThisMac(display)
        attempt.endpoint = endpoint
        endpoint.onReady = {
          attempt.ready = true; emit(.ready)
        }
        session.onConnectionChanged = { transport in
          guard ["failed", "disconnected", "closed"].contains(transport), attempt.outcome == nil else { return }
          attempt.transportEnded = true
          attempt.outcome =
            attempt.ready && restarts < 3 && transport != "closed"
            ? .lost : .ended("The screen-sharing connection ended. Reconnect to continue.")
          attempt.body?.cancel()
        }
        emit(.opened(endpoint))
        let offer = try await session.offer()
        try Task.checkCancellation()
        attempt.started = true
        var start = request(restarts == 0 ? .start : .restart, viewerId: viewerId, displayId: display, offer: offer)
        let media = await tunnelMedia?()
        attempt.tunnelMedia = media
        if let media { start.tunnelMedia = .init(endpointId: media.endpointId, flowId: media.flowId) }
        let reply = try await ScreenSharingTransientRetry.run(sleep: sleep) { [client, start] in
          try await client.screenSharing(start)
        }
        try Task.checkCancellation()
        guard reply.version == 1, reply.status == "connecting", let answer = reply.answer else {
          return .ended(reply.message ?? "This Mac cannot start screen sharing right now.")
        }
        try await session.accept(Self.remoteAnswer(answer, offer: offer, media: media, bridge: reply.tunnelMedia))
        var waitedForVideo = Duration.zero
        var notice = reply.message
        if notice != nil { emit(.hostNotice(notice)) }
        while true {
          try await sleep(heartbeatInterval)
          try Task.checkCancellation()
          let reply = try await client.screenSharing(request(.heartbeat, viewerId: viewerId))
          try Task.checkCancellation()
          guard reply.version == 1, ["connecting", "viewing"].contains(reply.status) else {
            return .ended(reply.message ?? "Screen sharing ended on the host Mac.")
          }
          if let failure = session.failure { return .ended(failure) }
          if reply.message != notice {
            notice = reply.message
            emit(.hostNotice(notice))
          }
          if !attempt.ready, notice == nil {
            waitedForVideo += heartbeatInterval
            guard waitedForVideo < Self.missingVideoTimeout else {
              return .ended(
                "No video arrived. Check the connection between these Macs or the configured relay, then retry.")
            }
          }
        }
      } catch {
        return isTaskCancellation(error) ? .cancelled : .ended(serverErrorMessage(error))
      }
    }
    attempt.body = body
    let result = await withTaskCancellationHandler {
      await body.value
    } onCancel: {
      body.cancel()
    }
    attempt.endpoint?.close()
    attempt.tunnelMedia?.close()
    var outcome = Task.isCancelled ? .cancelled : (attempt.outcome ?? result)
    if attempt.transportEnded, attempt.started, !Task.isCancelled, let reason = await hostEndReason(viewerId: viewerId)
    {
      outcome = .ended(reason)
    }
    return (outcome, attempt.started)
  }

  private static let missingVideoTimeout: Duration = .seconds(24)

  private func hostEndReason(viewerId: UUID) async -> String? {
    let heartbeat = request(.heartbeat, viewerId: viewerId)
    let client = client
    guard let reply = try? await Task(operation: { try await client.screenSharing(heartbeat) }).value,
      reply.status == "failed"
    else { return nil }
    return reply.message
  }

  static func remoteAnswer(
    _ answer: String, offer: String, media: ScreenSharingTunnelMedia?, bridge: ServerScreenSharingTunnelMediaBridge?
  ) -> String {
    guard let media, bridge?.flowId == media.flowId,
      let address = ScreenSharingTunnelSDP.localIPv4(inOffer: offer)
    else { return answer }
    return ScreenSharingTunnelSDP.answer(answer, routedTo: address, port: media.localPort)
  }

  private func request(
    _ operation: ServerScreenSharingRequest.Operation, viewerId: UUID, displayId: String? = nil, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspaceId, paneId: paneId, viewerId: viewerId,
      displayId: displayId ?? target, offer: offer)
  }

  private struct ViewerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
