import CodevisorCore
import CoreGraphics
import Foundation
import OSLog
import ScreenSharing
import ScreenSharingV2

enum SimulatorStreamTarget {
  static let prefix = "simulator:"

  static func udid(from displayId: String?) -> String? {
    guard let displayId, displayId.hasPrefix(prefix) else { return nil }
    let id = String(displayId.dropFirst(prefix.count))
    return UUID(uuidString: id)?.uuidString
  }
}

@MainActor
protocol SimulatorStreamPeer: SimulatorFrameSink {
  var channel: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { get }
  var onConnectionChanged: ((String) -> Void)? { get set }
  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant
  func close()
}

@MainActor
final class SimulatorV2Peer: SimulatorStreamPeer {
  private let stream: ScreenSharingV2StreamLink
  private let viewerEndpointId: String
  private nonisolated let frames: ScreenSharingV2LatestFrame

  init(size: CGSize, viewerEndpointId: String, encoder: ScreenSharingV2EncoderKind) throws {
    stream = ScreenSharingV2StreamLink(configuration: try Self.configuration(size: size), encoder: encoder)
    self.viewerEndpointId = viewerEndpointId
    frames = stream.frames
  }

  private static func configuration(size: CGSize) throws -> ScreenSharingVideoConfiguration {
    try ScreenSharingV2Profile.captureConfiguration(width: Int(size.width), height: Int(size.height))
  }

  var channel: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { stream.link.linkChannels.simulator }

  var onConnectionChanged: ((String) -> Void)? {
    get { stream.link.onConnectionChanged }
    set { stream.link.onConnectionChanged = newValue }
  }

  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant {
    try await stream.listen(for: viewerEndpointId, failed: failed)
  }

  func prepare(size: CGSize) {
    guard let configuration = try? Self.configuration(size: size) else { return }

    stream.link.updateVideoConfiguration(configuration)
  }

  nonisolated func push(_ frame: ScreenSharingVideoFrame) { frames.push(frame) }

  func close() { stream.close() }
}

@MainActor
final class SimulatorStreamHost {
  static let maximumSessions = 6
  static let lifetime: TimeInterval = 25
  static let screenWait = (tries: 60, interval: Duration.milliseconds(50))
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "SimulatorStream")

  private typealias Owner = ScreenSharingStreamOwner

  private final class Session: ScreenSharingStreamSession {
    let udid: String
    let peer: any SimulatorStreamPeer
    let attempt: UUID
    let token: String?
    var state = "connecting"
    var expiresAt: TimeInterval
    init(udid: String, peer: any SimulatorStreamPeer, attempt: UUID, token: String?, expiresAt: TimeInterval) {
      self.udid = udid; self.peer = peer; self.attempt = attempt; self.token = token; self.expiresAt = expiresAt
    }
  }

  private final class Viewed {
    let device: any SimulatorStreamDevice
    var viewers = 0
    init(device: any SimulatorStreamDevice) { self.device = device }
  }

  private let dependencies: SimulatorStreamHostDependencies
  private let identity: ScreenSharingStreamIdentity
  private let hosting: ScreenSharingHostActivity.Claim
  private var sessions: [Owner: Session] = [:] { didSet { hosting.isHosting = !sessions.isEmpty } }
  private var devices: [String: Viewed] = [:]
  private var watchdog: Task<Void, Never>?
  private var isShutdown = false

  private var now: TimeInterval { dependencies.now() }

  init(dependencies: SimulatorStreamHostDependencies = .live, activity: ScreenSharingHostActivity = .shared) {
    self.dependencies = dependencies
    hosting = activity.claim()
    identity = ScreenSharingStreamIdentity(hostKey: dependencies.hostKey, now: dependencies.now)
  }

  var sessionCount: Int { sessions.count }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    await identity.describing(await respond(to: request), for: request)
  }

  private func respond(to request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown else { return .init(status: "stopped") }
    guard request.version == 1 else { return Self.updateNeeded }
    if let refusal = identity.refusal(toIdentify: request) { return refusal }
    guard let udid = SimulatorStreamTarget.udid(from: request.displayId) else {
      return .init(status: "failed", message: "Invalid simulator.")
    }

    expireSessions()
    switch request.operation {
    case .capabilities: return capabilities(request, udid: udid)
    case .stop: return stop(request)
    case .setScale: return .init(status: "unsupported", message: "A simulator's scale can't be set.")
    case .heartbeat: return heartbeat(request, udid: udid)
    case .start: return await admit(request, udid: udid)
    case .restart: return ScreenSharingStreamIdentity.updateNeeded
    }
  }

  private func stop(_ request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    if let owner = identity.owner(stoppedBy: request, among: sessions), let session = sessions[owner] {
      end(owner: owner, session: session)
    }
    return .init(status: "stopped")
  }

  private func heartbeat(_ request: ServerScreenSharingRequest, udid: String) -> ServerScreenSharingReply {
    guard let owner = identity.owner(heartbeating: request, among: sessions), let session = sessions[owner],
      session.udid == udid
    else { return .init(status: "stopped", message: "The simulator stopped streaming.") }
    guard (try? dependencies.isBooted(udid)) == true else {
      end(owner: owner, session: session)
      return Self.nothingToView(status: "stopped", message: "The simulator shut down.")
    }

    session.expiresAt = now + Self.lifetime
    return .init(status: session.state)
  }

  private func admit(_ request: ServerScreenSharingRequest, udid: String) async -> ServerScreenSharingReply {
    if let refusal = await identity.refusal(toStart: request) { return refusal }

    guard let owner = identity.begin(request, target: udid) else {
      return ScreenSharingStreamIdentity.updateNeeded
    }
    defer { identity.finish(request, as: owner) }
    return await start(request, owner: owner, udid: udid)
  }

  private func capabilities(_ request: ServerScreenSharingRequest, udid: String) -> ServerScreenSharingReply {
    guard dependencies.isLoaded() else { return Self.noXcode }
    do {
      guard try dependencies.isBooted(udid) else {
        return Self.nothingToView(status: "starting", message: "The simulator is starting.")
      }
      var reply = ServerScreenSharingReply(
        status: "available",
        displays: [.init(id: request.displayId ?? "", name: "Simulator", width: 0, height: 0)])
      if dependencies.offersV2() { reply.engines = [ScreenSharingEngine.v2.rawValue] }
      return reply
    } catch {
      return .init(status: "unavailable", message: error.localizedDescription)
    }
  }

  private func start(
    _ request: ServerScreenSharingRequest, owner: Owner, udid: String
  ) async -> ServerScreenSharingReply {
    if let old = sessions[owner] { end(owner: owner, session: old) }
    guard sessions.count < Self.maximumSessions else {
      return .init(status: "busy", message: "Too many panes are showing simulators on this Mac.")
    }
    guard let media = ScreenSharingStreamMedia(request) else {
      return .init(status: "failed", message: "Invalid simulator request.")
    }
    do {
      let device = try attach(udid: udid)
      guard let size = await screenSize(of: device) else {
        release(udid: udid)
        return Self.nothingToView(status: "starting", message: "The simulator's screen isn't ready yet.")
      }
      guard identity.isStillStarting(request, as: owner) else {
        release(udid: udid)
        return .init(status: "stopped")
      }
      let peer: any SimulatorStreamPeer
      do {
        peer = try dependencies.makePeer(size, media, request.chroma)
      } catch {
        release(udid: udid)
        throw error
      }
      guard !isShutdown else {
        peer.close()
        release(udid: udid)
        return .init(status: "stopped")
      }
      let session = Session(
        udid: udid, peer: peer, attempt: request.viewerId, token: identity.token(for: owner),
        expiresAt: now + Self.lifetime)
      return try await connect(session, device: device, owner: owner)
    } catch {
      return .init(status: "failed", message: error.localizedDescription)
    }
  }

  private func screenSize(of device: any SimulatorStreamDevice) async -> CGSize? {
    for _ in 0..<Self.screenWait.tries where device.screenSize == nil {
      await dependencies.sleep(Self.screenWait.interval)
    }
    return device.screenSize
  }

  private func connect(
    _ session: Session, device: any SimulatorStreamDevice, owner: Owner
  ) async throws -> ServerScreenSharingReply {
    let (peer, udid) = (session.peer, session.udid)
    sessions[owner] = session
    peer.onConnectionChanged = { [weak self, weak session] state in
      guard let self, let session, self.sessions[owner] === session else { return }
      if state == "connected" { session.state = "viewing" }
      if ["disconnected", "failed", "closed"].contains(state) { session.state = "reconnecting" }
    }
    peer.channel.onMessage = { [weak self] message in self?.receive(message, udid: udid) }
    peer.channel.onAvailabilityChanged = { [weak self, weak peer] open in
      guard open, let self, let peer, let device = self.devices[udid]?.device else { return }
      peer.channel.send(.state(device.state))
    }
    startWatchdog()
    do {
      let grant = try await peer.start { [weak self, weak session] _ in
        guard let self, let session, self.sessions[owner] === session else { return }
        self.end(owner: owner, session: session)
      }
      guard !isShutdown, sessions[owner] === session else { throw CancellationError() }
      device.show(to: peer)
      Self.logger.notice("Stream granted to an app: \(self.sessions.count) viewing")
      return .connecting(grant, session: session.token)
    } catch {
      if sessions[owner] === session { end(owner: owner, session: session) }
      throw error
    }
  }

  func shutdown() {
    isShutdown = true
    for (owner, session) in sessions { end(owner: owner, session: session) }
    watchdog?.cancel()
    watchdog = nil
  }

  private func attach(udid: String) throws -> any SimulatorStreamDevice {
    let viewed = try devices[udid] ?? open(udid)
    viewed.viewers += 1
    do {
      try viewed.device.startCapturing()
    } catch {
      release(udid: udid)
      throw error
    }
    return viewed.device
  }

  private func open(_ udid: String) throws -> Viewed {
    guard dependencies.isLoaded() else { throw SimulatorRuntime.Failure("Xcode's simulators aren't available.") }

    let viewed = Viewed(device: try dependencies.openDevice(udid))
    devices[udid] = viewed
    viewed.device.onChange = { [weak self] in self?.deviceChanged(udid: udid) }
    return viewed
  }

  private func release(udid: String) {
    guard let viewed = devices[udid] else { return }

    viewed.viewers -= 1
    guard viewed.viewers <= 0 else { return }

    viewed.device.close()
    devices[udid] = nil
  }

  private func deviceChanged(udid: String) {
    guard let state = devices[udid]?.device.state else { return }

    for session in sessions.values where session.udid == udid { session.peer.channel.send(.state(state)) }
  }

  private func receive(_ message: ScreenSharingSimulatorMessage, udid: String) {
    devices[udid]?.device.receive(message)
  }

  private func end(owner: Owner, session: Session) {
    guard sessions[owner] === session else { return }
    sessions.removeValue(forKey: owner)
    session.peer.onConnectionChanged = nil
    session.peer.channel.onMessage = nil
    session.peer.channel.onAvailabilityChanged = nil
    devices[session.udid]?.device.hide(from: session.peer)
    devices[session.udid]?.device.releaseTouches()
    session.peer.close()
    release(udid: session.udid)
    Self.logger.notice("Stream ended: \(self.sessions.count) viewing")
    if sessions.isEmpty {
      watchdog?.cancel()
      watchdog = nil
    }
  }

  private func expireSessions() {
    let now = now
    for (owner, session) in sessions where now >= session.expiresAt { end(owner: owner, session: session) }
    if sessions.isEmpty {
      watchdog?.cancel()
      watchdog = nil
    }
  }

  private func startWatchdog() {
    guard watchdog == nil else { return }
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled else { return }
        self.expireSessions()
      }
    }
  }

  private static func nothingToView(status: String, message: String) -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: status, message: message)
    reply.reason = .nothingToView
    return reply
  }

  private static var updateNeeded: ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: "unavailable", message: "Update Codevisor on this Mac.")
    reply.reason = .updateNeeded
    return reply
  }

  private static let noXcode = ServerScreenSharingReply(
    status: "unavailable", message: "Install Xcode on this Mac to use its simulators.")
}
