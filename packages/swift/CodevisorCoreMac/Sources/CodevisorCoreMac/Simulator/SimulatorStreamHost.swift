import CodevisorCore
import CoreGraphics
import Foundation
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

  private final class Device {
    let control: SimulatorDeviceControl
    var capture: SimulatorScreenCapture?
    var displayName: String?
    var viewers = 0
    init(control: SimulatorDeviceControl) { self.control = control }
  }

  private let identity = ScreenSharingStreamIdentity()
  private var sessions: [Owner: Session] = [:]
  private var devices: [String: Device] = [:]
  private var watchdog: Task<Void, Never>?
  private var isShutdown = false

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    await identity.describing(await respond(to: request), for: request)
  }

  private func respond(to request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown else { return .init(status: "stopped") }
    guard request.version == 1 else { return Self.updateNeeded }
    guard let udid = SimulatorStreamTarget.udid(from: request.displayId) else {
      return .init(status: "failed", message: "Invalid simulator.")
    }

    expireSessions()
    switch request.operation {
    case .capabilities: return capabilities(request, udid: udid)
    case .stop: return stop(request)
    case .setScale: return .init(status: "unsupported", message: "A simulator's scale can't be set.")
    case .heartbeat: return heartbeat(request, udid: udid)
    case .start, .restart: return await admit(request, udid: udid)
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
    guard (try? SimulatorRuntime.device(udid: udid)).map(SimulatorRuntime.isBooted) == true else {
      end(owner: owner, session: session)
      return Self.nothingToView(status: "stopped", message: "The simulator shut down.")
    }

    session.expiresAt = now + Self.lifetime
    return .init(status: session.state)
  }

  private func admit(_ request: ServerScreenSharingRequest, udid: String) async -> ServerScreenSharingReply {
    if let refusal = await identity.refusal(toStart: request) { return refusal }

    let owner = identity.begin(request, target: udid)
    defer { identity.finish(request, as: owner) }
    return await start(request, owner: owner, udid: udid)
  }

  private func capabilities(_ request: ServerScreenSharingRequest, udid: String) -> ServerScreenSharingReply {
    guard SimulatorRuntime.loaded else { return Self.noXcode }
    do {
      let device = try SimulatorRuntime.device(udid: udid)
      guard SimulatorRuntime.isBooted(device) else {
        return Self.nothingToView(status: "starting", message: "The simulator is starting.")
      }
      var reply = ServerScreenSharingReply(
        status: "available",
        displays: [.init(id: request.displayId ?? "", name: "Simulator", width: 0, height: 0)])
      if ScreenSharingMediaEndpoint.shared.isAvailable { reply.engines = [ScreenSharingEngine.v2.rawValue] }
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
      var size = device.capture?.size
      for _ in 0..<60 where size == nil {
        try? await Task.sleep(for: .milliseconds(50))
        size = device.capture?.size
      }
      guard let capture = device.capture, let size else {
        release(udid: udid)
        return Self.nothingToView(status: "starting", message: "The simulator's screen isn't ready yet.")
      }
      guard identity.isStillStarting(request, as: owner) else {
        release(udid: udid)
        return .init(status: "stopped")
      }
      let peer: any SimulatorStreamPeer
      do {
        peer = try makePeer(size: size, media: media, request: request)
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
      return try await connect(session, capture: capture, owner: owner)
    } catch {
      return .init(status: "failed", message: error.localizedDescription)
    }
  }

  private func connect(
    _ session: Session, capture: SimulatorScreenCapture, owner: Owner
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
      guard open, let self, let peer, let device = self.devices[udid] else { return }
      peer.channel.send(.state(device.control.state))
    }
    startWatchdog()
    do {
      let grant = try await peer.start { [weak self, weak session] _ in
        guard let self, let session, self.sessions[owner] === session else { return }
        self.end(owner: owner, session: session)
      }
      guard !isShutdown, sessions[owner] === session else { throw CancellationError() }
      capture.add(peer)
      return .connecting(grant, session: session.token)
    } catch {
      if sessions[owner] === session { end(owner: owner, session: session) }
      throw error
    }
  }

  private func makePeer(
    size: CGSize, media: ScreenSharingStreamMedia, request: ServerScreenSharingRequest
  ) throws -> any SimulatorStreamPeer {
    try SimulatorV2Peer(
      size: size, viewerEndpointId: media.viewerEndpointId, encoder: .forViewer(chroma: request.chroma))
  }

  func shutdown() {
    isShutdown = true
    for (owner, session) in sessions { end(owner: owner, session: session) }
    watchdog?.cancel()
    watchdog = nil
  }

  private func attach(udid: String) throws -> Device {
    let device: Device
    if let existing = devices[udid] {
      device = existing
    } else {
      guard SimulatorRuntime.loaded else { throw SimulatorRuntime.Failure("Xcode's simulators aren't available.") }
      let control = try SimulatorDeviceControl(udid: udid)
      device = Device(control: control)
      devices[udid] = device
      control.onChange = { [weak self] in self?.deviceChanged(udid: udid) }
    }
    device.viewers += 1
    if device.capture == nil { try startCapture(device) }
    return device
  }

  private func startCapture(_ device: Device) throws {
    let wanted = device.control.displayName
    let screens = try SimulatorRuntime.screens(SimulatorRuntime.device(udid: device.control.udid))
    let screen =
      screens.first { $0.name == wanted } ?? screens.first { $0.type == 0 } ?? screens.first
    guard let screen else { throw SimulatorRuntime.Failure("The simulator has no screen to show.") }
    let capture = SimulatorScreenCapture(screen: screen)
    device.capture = capture
    device.displayName = screen.name
    capture.start()
  }

  private func turns(_ device: Device) -> Int {
    let held = device.control.canRotate ? device.control.orientation.quarterTurns : 0
    return held + device.control.screenTurns
  }

  private func release(udid: String) {
    guard let device = devices[udid] else { return }
    device.viewers -= 1
    guard device.viewers <= 0 else { return }
    device.capture?.stop()
    device.control.close()
    devices[udid] = nil
  }

  private func deviceChanged(udid: String) {
    guard let device = devices[udid] else { return }
    if device.control.displayName != device.displayName, let old = device.capture {
      old.stop()
      device.capture = nil
      try? startCapture(device)
      for session in sessions.values where session.udid == udid { device.capture?.add(session.peer) }
    }
    let state = device.control.state
    for session in sessions.values where session.udid == udid { session.peer.channel.send(.state(state)) }
  }

  private func receive(_ message: ScreenSharingSimulatorMessage, udid: String) {
    guard let device = devices[udid] else { return }
    apply(message, to: device.control, turns: turns(device))
  }

  private func apply(_ message: ScreenSharingSimulatorMessage, to control: SimulatorDeviceControl, turns: Int) {
    switch message {
    case .touch(let phase, let touches):
      control.touch(
        phase,
        touches.prefix(5).map { touch in
          (
            touch.id, Self.framebufferPoint(x: touch.x, y: touch.y, turns: turns),
            Self.edgeCode(touch.edge, turns: turns)
          )
        })
    case .button(let name, let down):
      control.button(name, down: down)
    case .key(let usage, let down):
      control.key(usage, down: down)
    case .rotate(let orientation):
      control.rotate(to: orientation)
    case .posture(let posture):
      control.setPosture(posture)
    case .crown, .state:
      break
    }
  }

  nonisolated static func framebufferPoint(x: Double, y: Double, turns: Int) -> CGPoint {
    let x = min(1, max(0, x)), y = min(1, max(0, y))
    switch ((turns % 4) + 4) % 4 {
    case 1: return CGPoint(x: y, y: 1 - x)
    case 2: return CGPoint(x: 1 - x, y: 1 - y)
    case 3: return CGPoint(x: 1 - y, y: x)
    default: return CGPoint(x: x, y: y)
    }
  }

  nonisolated static func edgeCode(_ edge: ScreenSharingSimulatorEdge?, turns: Int) -> UInt64 {
    guard let edge else { return 0 }
    let order: [ScreenSharingSimulatorEdge] = [.top, .right, .bottom, .left]
    guard let index = order.firstIndex(of: edge) else { return 0 }
    let native = order[(((index - turns) % 4) + 4) % 4]
    switch native {
    case .top: return 1
    case .left: return 2
    case .bottom: return 3
    case .right: return 4
    }
  }

  private func end(owner: Owner, session: Session) {
    guard sessions[owner] === session else { return }
    sessions.removeValue(forKey: owner)
    session.peer.onConnectionChanged = nil
    session.peer.channel.onMessage = nil
    session.peer.channel.onAvailabilityChanged = nil
    devices[session.udid]?.capture?.remove(session.peer)
    devices[session.udid]?.control.releaseTouches()
    session.peer.close()
    release(udid: session.udid)
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
