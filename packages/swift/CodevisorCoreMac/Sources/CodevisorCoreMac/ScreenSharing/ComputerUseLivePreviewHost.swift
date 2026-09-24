import CodevisorCore
import CoreGraphics
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

// MARK: - Target addressing

/// `computer-use:<chat session id>` — the window that chat's agent controls.
enum ComputerUseStreamTarget {
  static let prefix = "computer-use:"

  static func displayId(sessionID: String) -> String { prefix + sessionID.lowercased() }

  /// The lowercased chat session id, or nil for anything else.
  static func sessionID(from displayId: String?) -> String? {
    guard let displayId, displayId.hasPrefix(prefix) else { return nil }
    let id = String(displayId.dropFirst(prefix.count))
    return UUID(uuidString: id) == nil ? nil : id.lowercased()
  }
}

// MARK: - Peer seam

/// The media side of one remote viewer. Production wraps a WebRTC sender;
/// tests substitute a fake.
@MainActor
protocol ComputerUseStreamPeer: AnyObject {
  var onConnectionChanged: ((String) -> Void)? { get set }
  /// Receives the window's frames and size changes.
  var sink: any ComputerUseFrameSink { get }
  func answer(offer: String) async throws -> String
  func close()
}

/// A view-only WebRTC sender: frames in, control requests politely denied.
@MainActor
final class ComputerUseSenderPeer: ComputerUseStreamPeer {
  private let sender: ScreenSharingSender
  private let control: ScreenSharingHostControl
  let sink: any ComputerUseFrameSink

  init(size: CGSize, connectivity: ServerScreenSharingConnectivity) throws {
    try ScreenSharingFieldTrials.process.install(profile: ScreenSharingDiagnosticProfile.process())
    let metrics = ScreenSharingMetrics()
    let configuration = try computerUseStreamVideoConfiguration(size: size)
    let sender = try ScreenSharingSender(
      configuration: configuration, metrics: metrics, connectivity: connectivity.native())
    self.sender = sender
    sink = ComputerUseSenderSink(sender: sender)
    control = ScreenSharingHostControl(
      availability: { "This live view is view-only." },
      inject: { _ in },
      send: { [weak sender] in sender?.controlChannel.send($0) ?? false }
    )
    sender.controlChannel.onMessage = { [weak control] in control?.receive($0) }
  }

  var onConnectionChanged: ((String) -> Void)? {
    get { sender.onConnectionChanged }
    set { sender.onConnectionChanged = newValue }
  }

  func answer(offer: String) async throws -> String {
    try await sender.accept(.init(kind: "offer", sdp: offer))
    return try await sender.makeDescription(offer: false).sdp
  }

  func close() {
    control.revoke("The live view ended.")
    sender.close()
  }
}

/// The WebRTC encoder rejects frames whose size differs from its last
/// configuration, so size changes reach it before the stream resizes.
final class ComputerUseSenderSink: ComputerUseFrameSink {
  private let frameSender: ScreenSharingFrameSender
  @MainActor private weak var sender: ScreenSharingSender?

  @MainActor init(sender: ScreenSharingSender) {
    self.sender = sender
    frameSender = sender.frameSender
  }

  @MainActor func prepare(size: CGSize) {
    guard let configuration = try? computerUseStreamVideoConfiguration(size: size) else { return }
    sender?.updateVideoConfiguration(configuration)
  }

  func push(_ frame: ScreenSharingVideoFrame) {
    frameSender.push(frame)
  }
}

/// The preview stream's sizes are already even; the encoder also needs 64+.
func computerUseStreamVideoConfiguration(size: CGSize) throws -> ScreenSharingVideoConfiguration {
  func dimension(_ value: CGFloat, limit: Int) -> Int {
    min(limit, max(64, Int(value) / 2 * 2))
  }
  return try ScreenSharingVideoConfiguration(
    width: dimension(size.width, limit: 3840),
    height: dimension(size.height, limit: 2160),
    framesPerSecond: Int(ComputerUseNativePreviewMetrics.viewingFramesPerSecond),
    bitrate: 3_000_000
  )
}

// MARK: - Host

/// Streams the window a chat's agent controls to that chat's remote viewers.
/// Unlike display sharing there is no exclusive lease: viewers only watch,
/// and each one's frames come from the same native sharing stream.
@MainActor
final class ComputerUseLivePreviewHost {
  struct Dependencies {
    var captureAccess: @MainActor () -> Bool
    var activity: @MainActor (_ sessionID: String) -> ComputerUseLivePreview.Activity?
    var streamSize: @MainActor (_ bridgeSessionID: String) -> CGSize?
    var attach: @MainActor (_ bridgeSessionID: String, _ sink: any ComputerUseFrameSink) -> UUID
    var detach: @MainActor (_ bridgeSessionID: String, _ token: UUID) -> Void
    var makePeer:
      @MainActor (_ size: CGSize, _ connectivity: ServerScreenSharingConnectivity) throws
        -> any ComputerUseStreamPeer
    var makeConnectivity: @MainActor (_ viewerId: UUID) throws -> ServerScreenSharingConnectivity
    var now: @MainActor () -> TimeInterval

    @MainActor static var live: Dependencies {
      let connectivity = ScreenSharingHostConnectivity(environment: ProcessInfo.processInfo.environment)
      return Dependencies(
        captureAccess: { CGPreflightScreenCaptureAccess() },
        activity: { ComputerUseLivePreview.shared.activity(forSessionID: $0) },
        streamSize: { ComputerUseNativeSharing.shared.previewSize(sessionID: $0) },
        attach: { ComputerUseLivePreview.shared.attachSink(sessionID: $0, sink: $1) },
        detach: { ComputerUseLivePreview.shared.detachSink(sessionID: $0, token: $1) },
        makePeer: { try ComputerUseSenderPeer(size: $0, connectivity: $1) },
        makeConnectivity: { try connectivity.make(viewerId: $0) },
        now: { ProcessInfo.processInfo.systemUptime }
      )
    }
  }

  static let maximumSessions = 4
  /// Matches the display lease: a viewer heartbeats every 8 s.
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
    let sessionID: String
    let bridgeSessionID: String
    let peer: any ComputerUseStreamPeer
    var token: UUID?
    var state = "connecting"
    var expiresAt: TimeInterval

    init(sessionID: String, bridgeSessionID: String, peer: any ComputerUseStreamPeer, expiresAt: TimeInterval) {
      self.sessionID = sessionID; self.bridgeSessionID = bridgeSessionID
      self.peer = peer; self.expiresAt = expiresAt
    }
  }

  private let dependencies: Dependencies
  private var sessions: [Owner: Session] = [:]
  private var watchdog: Task<Void, Never>?
  private var isShutdown = false

  init(dependencies: Dependencies = .live) {
    self.dependencies = dependencies
  }

  var sessionCount: Int { sessions.count }

  func handle(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    guard !isShutdown else { return .init(status: "stopped") }
    guard request.version == 1 else {
      return .init(status: "unavailable", message: "Update Codevisor to use the live view.")
    }
    guard let sessionID = ComputerUseStreamTarget.sessionID(from: request.displayId) else {
      return .init(status: "failed", message: "Invalid live view target.")
    }
    expireSessions()
    let owner = Owner(request)
    switch request.operation {
    case .capabilities:
      guard dependencies.captureAccess() else { return Self.permissionRequired }
      guard let activity = liveActivity(sessionID) else { return Self.notControlling }
      do {
        return .init(
          status: "available",
          displays: [display(for: activity, target: request.displayId ?? "")],
          connectivity: try dependencies.makeConnectivity(request.viewerId))
      } catch { return .init(status: "unavailable", message: error.localizedDescription) }
    case .stop:
      if let session = sessions[owner] { end(owner: owner, session: session) }
      return .init(status: "stopped")
    case .setScale:
      return .init(status: "unsupported", message: "A live view's scale can't be set.")
    case .heartbeat:
      guard let session = sessions[owner], session.sessionID == sessionID else {
        return .init(status: "stopped", message: "The live view ended on the host Mac.")
      }
      guard liveActivity(sessionID) != nil else {
        end(owner: owner, session: session)
        return .init(status: "stopped", message: "The agent stopped controlling the app.")
      }
      session.expiresAt = dependencies.now() + Self.lifetime
      return .init(status: session.state)
    case .start, .restart:
      if let old = sessions[owner] { end(owner: owner, session: old) }
      guard sessions.count < Self.maximumSessions else {
        return .init(status: "busy", message: "Too many viewers are watching this agent.")
      }
      guard dependencies.captureAccess() else { return Self.permissionRequired }
      guard let offer = request.offer, offer.utf8.count <= 256 * 1024,
        offer.contains("a=fingerprint:sha-256 ")
      else { return .init(status: "failed", message: "Invalid live view request.") }
      guard let activity = liveActivity(sessionID) else { return Self.notControlling }
      let size = dependencies.streamSize(activity.bridgeSessionID) ?? activity.windowFrame.size
      do {
        let peer = try dependencies.makePeer(size, try dependencies.makeConnectivity(request.viewerId))
        let session = Session(
          sessionID: sessionID, bridgeSessionID: activity.bridgeSessionID, peer: peer,
          expiresAt: dependencies.now() + Self.lifetime)
        sessions[owner] = session
        peer.onConnectionChanged = { [weak self, weak session] state in
          guard let self, let session, self.sessions[owner] === session else { return }
          if state == "connected" {
            session.state = "viewing"
          } else if ["disconnected", "failed", "closed"].contains(state) {
            session.state = "reconnecting"
          }
        }
        startWatchdog()
        do {
          let answer = try await peer.answer(offer: offer)
          guard !isShutdown, sessions[owner] === session else { throw CancellationError() }
          // Frames flow only once the answer is out; the sink is told the
          // current size first.
          session.token = dependencies.attach(session.bridgeSessionID, peer.sink)
          return .init(status: "connecting", answer: answer)
        } catch {
          if sessions[owner] === session { end(owner: owner, session: session) } else { peer.close() }
          throw error
        }
      } catch { return .init(status: "failed", message: error.localizedDescription) }
    }
  }

  /// Ends every viewer of a chat whose agent stopped controlling its app.
  func activityChanged() {
    for (owner, session) in sessions where liveActivity(session.sessionID) == nil {
      end(owner: owner, session: session)
    }
  }

  func shutdown() {
    isShutdown = true
    for (owner, session) in sessions { end(owner: owner, session: session) }
    watchdog?.cancel()
    watchdog = nil
  }

  private func liveActivity(_ sessionID: String) -> ComputerUseLivePreview.Activity? {
    guard let activity = dependencies.activity(sessionID), activity.state == .active else { return nil }
    return activity
  }

  private func display(for activity: ComputerUseLivePreview.Activity, target: String) -> ServerScreenSharingDisplay {
    let size = dependencies.streamSize(activity.bridgeSessionID) ?? activity.windowFrame.size
    return .init(id: target, name: activity.appName, width: Int(size.width), height: Int(size.height))
  }

  private func end(owner: Owner, session: Session) {
    guard sessions[owner] === session else { return }
    sessions.removeValue(forKey: owner)
    if let token = session.token { dependencies.detach(session.bridgeSessionID, token) }
    session.token = nil
    session.peer.onConnectionChanged = nil
    session.peer.close()
    if sessions.isEmpty {
      watchdog?.cancel()
      watchdog = nil
    }
  }

  private func expireSessions() {
    let now = dependencies.now()
    for (owner, session) in sessions where now >= session.expiresAt {
      end(owner: owner, session: session)
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

  private static let permissionRequired = ServerScreenSharingReply(
    status: "permission-required",
    message: "Allow Screen Recording for Codevisor on the host Mac.")
  private static let notControlling = ServerScreenSharingReply(
    status: "unavailable", message: "The agent is not controlling an app right now.")
}
