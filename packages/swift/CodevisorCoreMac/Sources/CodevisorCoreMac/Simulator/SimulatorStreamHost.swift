import CodevisorCore
import CoreGraphics
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

/// `simulator:<udid>` — an Apple simulator's screen.
enum SimulatorStreamTarget {
  static let prefix = "simulator:"

  static func udid(from displayId: String?) -> String? {
    guard let displayId, displayId.hasPrefix(prefix) else { return nil }
    let id = String(displayId.dropFirst(prefix.count))
    return UUID(uuidString: id)?.uuidString
  }
}

/// A viewer's WebRTC sender: the simulator's frames out, its input and commands in on the
/// simulator channel.
@MainActor
final class SimulatorSenderPeer: SimulatorFrameSink {
  private let sender: ScreenSharingSender
  private let frameSender: ScreenSharingFrameSender

  init(size: CGSize, connectivity: ServerScreenSharingConnectivity) async throws {
    try ScreenSharingFieldTrials.process.install(profile: ScreenSharingDiagnosticProfile.process())
    var options = ScreenSharingPeerOptions()
    options.codec = .hevc
    options.fallbackCodecs = [.h264]
    let sender = try await ScreenSharingSender(
      configuration: try Self.configuration(size: size), metrics: ScreenSharingMetrics(), options: options,
      connectivity: connectivity.native())
    self.sender = sender
    frameSender = sender.frameSender
  }

  static func configuration(size: CGSize) throws -> ScreenSharingVideoConfiguration {
    try ScreenSharingVideoConfiguration(
      width: Int(size.width), height: Int(size.height), framesPerSecond: 60, bitrate: 10_000_000)
  }

  var channel: ScreenSharingSimulatorChannel { sender.simulatorChannel }

  var onConnectionChanged: ((String) -> Void)? {
    get { sender.onConnectionChanged }
    set { sender.onConnectionChanged = newValue }
  }

  func answer(offer: String) async throws -> String {
    try await sender.accept(.init(kind: "offer", sdp: offer))
    return try await sender.makeDescription(offer: false).sdp
  }

  func prepare(size: CGSize) {
    guard let configuration = try? Self.configuration(size: size) else { return }
    sender.updateVideoConfiguration(configuration)
  }

  nonisolated func push(_ frame: ScreenSharingVideoFrame) { frameSender.push(frame) }

  func close() { sender.close() }
}

/// Streams booted simulators to Simulator panes. Viewers of the same simulator share its
/// capture and its input: a rotation or posture change made in one pane shows in all of them.
@MainActor
final class SimulatorStreamHost {
  static let maximumSessions = 6
  /// A viewer heartbeats every 8 s.
  static let lifetime: TimeInterval = 25

  private struct Owner: Hashable {
    let workspaceId: UUID
    let paneId: UUID
    let viewerId: UUID
    init(_ request: ServerScreenSharingRequest) {
      workspaceId = request.workspaceId; paneId = request.paneId; viewerId = request.viewerId
    }
  }

  private final class Session {
    let udid: String
    let peer: SimulatorSenderPeer
    var state = "connecting"
    var expiresAt: TimeInterval
    init(udid: String, peer: SimulatorSenderPeer, expiresAt: TimeInterval) {
      self.udid = udid; self.peer = peer; self.expiresAt = expiresAt
    }
  }

  /// One device's capture and input, alive while anyone watches it.
  private final class Device {
    let control: SimulatorDeviceControl
    var capture: SimulatorScreenCapture?
    var displayName: String?
    var viewers = 0
    init(control: SimulatorDeviceControl) { self.control = control }
  }

  private var sessions: [Owner: Session] = [:]
  private var devices: [String: Device] = [:]
  private var watchdog: Task<Void, Never>?
  private var isShutdown = false
  private let connectivity = ScreenSharingHostConnectivity(environment: ProcessInfo.processInfo.environment)

  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown else { return .init(status: "stopped") }
    guard request.version == 1 else { return .init(status: "unavailable", message: "Update Codevisor on this Mac.") }
    guard let udid = SimulatorStreamTarget.udid(from: request.displayId) else {
      return .init(status: "failed", message: "Invalid simulator.")
    }
    expireSessions()
    let owner = Owner(request)
    switch request.operation {
    case .capabilities:
      guard SimulatorRuntime.loaded else { return Self.noXcode }
      do {
        let device = try SimulatorRuntime.device(udid: udid)
        // A device still booting is worth waiting for; the viewer retries "starting".
        guard SimulatorRuntime.isBooted(device) else {
          return .init(status: "starting", message: "The simulator is starting.")
        }
        return .init(
          status: "available",
          displays: [.init(id: request.displayId ?? "", name: "Simulator", width: 0, height: 0)],
          connectivity: try connectivity.make(viewerId: request.viewerId))
      } catch {
        return .init(status: "unavailable", message: error.localizedDescription)
      }
    case .stop:
      if let session = sessions[owner] { end(owner: owner, session: session) }
      return .init(status: "stopped")
    case .setScale:
      return .init(status: "unsupported", message: "A simulator's scale can't be set.")
    case .heartbeat:
      guard let session = sessions[owner], session.udid == udid else {
        return .init(status: "stopped", message: "The simulator stopped streaming.")
      }
      guard (try? SimulatorRuntime.device(udid: udid)).map(SimulatorRuntime.isBooted) == true else {
        end(owner: owner, session: session)
        return .init(status: "stopped", message: "The simulator shut down.")
      }
      session.expiresAt = now + Self.lifetime
      return .init(status: session.state)
    case .start, .restart:
      if let old = sessions[owner] { end(owner: owner, session: old) }
      guard sessions.count < Self.maximumSessions else {
        return .init(status: "busy", message: "Too many panes are showing simulators on this Mac.")
      }
      guard let offer = request.offer, offer.utf8.count <= 256 * 1024, offer.contains("a=fingerprint:sha-256 ") else {
        return .init(status: "failed", message: "Invalid simulator request.")
      }
      do {
        let device = try attach(udid: udid)
        // The framebuffer appears once the screen callbacks are registered; give it a moment.
        var size = device.capture?.size
        for _ in 0..<60 where size == nil {
          try? await Task.sleep(for: .milliseconds(50))
          size = device.capture?.size
        }
        guard let capture = device.capture, let size else {
          release(udid: udid)
          return .init(status: "starting", message: "The simulator's screen isn't ready yet.")
        }
        let peer: SimulatorSenderPeer
        do {
          peer = try await SimulatorSenderPeer(
            size: size, connectivity: try connectivity.make(viewerId: request.viewerId))
        } catch {
          release(udid: udid)
          throw error
        }
        guard !isShutdown else {
          peer.close()
          release(udid: udid)
          return .init(status: "stopped")
        }
        let session = Session(udid: udid, peer: peer, expiresAt: now + Self.lifetime)
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
          let answer = try await peer.answer(offer: offer)
          guard !isShutdown, sessions[owner] === session else { throw CancellationError() }
          capture.add(peer)
          return .init(status: "connecting", answer: answer)
        } catch {
          if sessions[owner] === session { end(owner: owner, session: session) }
          throw error
        }
      } catch {
        return .init(status: "failed", message: error.localizedDescription)
      }
    }
  }

  func shutdown() {
    isShutdown = true
    for (owner, session) in sessions { end(owner: owner, session: session) }
    watchdog?.cancel()
    watchdog = nil
  }

  // MARK: Devices

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

  /// Clockwise quarter turns from the framebuffer to what the viewer sees: how the screen is
  /// mounted in the device, then how the device is held. Viewers turn frame and screen together
  /// this far, like glass in a real device, and touches arrive in this space.
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

  /// The device turned or folded: re-aim the capture and tell every viewer.
  private func deviceChanged(udid: String) {
    guard let device = devices[udid] else { return }  // Snapshot viewers read state from replies.
    if device.control.displayName != device.displayName, let old = device.capture {
      // A foldable swapped screens: move every viewer to the other framebuffer.
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

  /// A point in the upright video back in framebuffer-normalized coordinates.
  nonisolated static func framebufferPoint(x: Double, y: Double, turns: Int) -> CGPoint {
    let x = min(1, max(0, x)), y = min(1, max(0, y))
    switch ((turns % 4) + 4) % 4 {
    case 1: return CGPoint(x: y, y: 1 - x)
    case 2: return CGPoint(x: 1 - x, y: 1 - y)
    case 3: return CGPoint(x: 1 - y, y: x)
    default: return CGPoint(x: x, y: y)
    }
  }

  /// The guest's edge codes: 1 top, 2 left, 3 bottom, 4 right, in framebuffer terms.
  nonisolated static func edgeCode(_ edge: ScreenSharingSimulatorEdge?, turns: Int) -> UInt64 {
    guard let edge else { return 0 }
    // Clockwise order on screen; turning the video back counterclockwise moves each edge back.
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

  // MARK: Sessions

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

  private static let noXcode = ServerScreenSharingReply(
    status: "unavailable", message: "Install Xcode on this Mac to use its simulators.")
}
