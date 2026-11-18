import CodevisorCore
import CoreGraphics
import Foundation
import ScreenSharing
import ScreenSharingV2

enum ComputerUseStreamTarget {
  static let prefix = "computer-use:"

  static func displayId(sessionID: String) -> String { prefix + sessionID.lowercased() }

  static func sessionID(from displayId: String?) -> String? {
    guard let displayId, displayId.hasPrefix(prefix) else { return nil }
    let id = String(displayId.dropFirst(prefix.count))
    return UUID(uuidString: id) == nil ? nil : id.lowercased()
  }
}

@MainActor
protocol ComputerUseStreamPeer: AnyObject {
  var onConnectionChanged: ((String) -> Void)? { get set }
  var sink: any ComputerUseFrameSink { get }
  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant
  func close()
}

@MainActor
private func viewOnlyControl(send: @escaping (ScreenSharingControlMessage) -> Bool) -> ScreenSharingHostControl {
  ScreenSharingHostControl(availability: { "This live view is view-only." }, inject: { _ in }, send: send)
}

@MainActor
final class ComputerUseV2Peer: ComputerUseStreamPeer {
  private let stream: ScreenSharingV2StreamLink
  private let viewerEndpointId: String
  private let control: ScreenSharingHostControl
  let sink: any ComputerUseFrameSink

  init(size: CGSize, viewerEndpointId: String) throws {
    let stream = ScreenSharingV2StreamLink(configuration: try computerUseStreamVideoConfiguration(size: size))
    self.stream = stream
    self.viewerEndpointId = viewerEndpointId
    sink = ComputerUseV2Sink(stream: stream)
    let channel = stream.link.linkChannels.control
    control = viewOnlyControl { [weak channel] in channel?.send($0) ?? false }
    channel.onMessage = { [weak control] in control?.receive($0) }
  }

  var onConnectionChanged: ((String) -> Void)? {
    get { stream.link.onConnectionChanged }
    set { stream.link.onConnectionChanged = newValue }
  }

  func start(failed: @escaping @MainActor (String) -> Void) async throws -> ServerScreenSharingMediaGrant {
    try await stream.listen(for: viewerEndpointId, failed: failed)
  }

  func close() {
    control.revoke("The live view ended.")
    stream.close()
  }
}

final class ComputerUseV2Sink: ComputerUseFrameSink {
  private let frames: ScreenSharingV2LatestFrame
  @MainActor private weak var link: ScreenSharingV2HostLink?

  @MainActor init(stream: ScreenSharingV2StreamLink) {
    link = stream.link
    frames = stream.frames
  }

  @MainActor func prepare(size: CGSize) {
    guard let configuration = try? computerUseStreamVideoConfiguration(size: size) else { return }
    link?.updateVideoConfiguration(configuration)
  }

  func push(_ frame: ScreenSharingVideoFrame) {
    frames.push(frame)
  }
}

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

@MainActor
final class ComputerUseLivePreviewHost {
  struct Dependencies {
    var captureAccess: @MainActor () -> Bool
    var activity: @MainActor (_ sessionID: String) -> ComputerUseLivePreview.Activity?
    var streamSize: @MainActor (_ bridgeSessionID: String) -> CGSize?
    var attach: @MainActor (_ bridgeSessionID: String, _ sink: any ComputerUseFrameSink) -> UUID
    var detach: @MainActor (_ bridgeSessionID: String, _ token: UUID) -> Void
    var makePeer:
      @MainActor (_ size: CGSize, _ media: ScreenSharingStreamMedia) async throws -> any ComputerUseStreamPeer
    var offersV2: @MainActor () -> Bool
    var hostKey: @MainActor () async -> String?
    var now: @MainActor () -> TimeInterval

    @MainActor static var live: Dependencies {
      Dependencies(
        captureAccess: { CGPreflightScreenCaptureAccess() },
        activity: { ComputerUseLivePreview.shared.activity(forSessionID: $0) },
        streamSize: { ComputerUseNativeSharing.shared.previewSize(sessionID: $0) },
        attach: { ComputerUseLivePreview.shared.attachSink(sessionID: $0, sink: $1) },
        detach: { ComputerUseLivePreview.shared.detachSink(sessionID: $0, token: $1) },
        makePeer: { size, media in try ComputerUseV2Peer(size: size, viewerEndpointId: media.viewerEndpointId) },
        offersV2: { ScreenSharingMediaEndpoint.shared.isAvailable },
        hostKey: { await ScreenSharingStreamIdentity.mediaEndpointKey() },
        now: { ProcessInfo.processInfo.systemUptime }
      )
    }
  }

  static let maximumSessions = 4
  static let lifetime: TimeInterval = 25

  private typealias Owner = ScreenSharingStreamOwner

  private final class Session: ScreenSharingStreamSession {
    let sessionID: String
    let bridgeSessionID: String
    let peer: any ComputerUseStreamPeer
    let attempt: UUID
    let token: String?
    var sink: UUID?
    var state = "connecting"
    var expiresAt: TimeInterval

    init(
      sessionID: String, activity: ComputerUseLivePreview.Activity, peer: any ComputerUseStreamPeer, attempt: UUID,
      token: String?, expiresAt: TimeInterval
    ) {
      self.sessionID = sessionID; bridgeSessionID = activity.bridgeSessionID
      self.peer = peer; self.attempt = attempt; self.token = token; self.expiresAt = expiresAt
    }
  }

  private let dependencies: Dependencies
  private let identity: ScreenSharingStreamIdentity
  private let hosting: ScreenSharingHostActivity.Claim
  private var sessions: [Owner: Session] = [:] { didSet { hosting.isHosting = !sessions.isEmpty } }
  private var watchdog: Task<Void, Never>?
  private var isShutdown = false

  init(dependencies: Dependencies = .live, activity: ScreenSharingHostActivity = .shared) {
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
    guard let sessionID = ComputerUseStreamTarget.sessionID(from: request.displayId) else {
      return .init(status: "failed", message: "Invalid live view target.")
    }

    expireSessions()
    switch request.operation {
    case .capabilities: return capabilities(request, sessionID: sessionID)
    case .stop: return stop(request)
    case .setScale: return .init(status: "unsupported", message: "A live view's scale can't be set.")
    case .heartbeat: return heartbeat(request, sessionID: sessionID)
    case .start: return await admit(request, sessionID: sessionID)
    case .restart: return ScreenSharingStreamIdentity.updateNeeded
    }
  }

  private func stop(_ request: ServerScreenSharingRequest) -> ServerScreenSharingReply {
    if let owner = identity.owner(stoppedBy: request, among: sessions), let session = sessions[owner] {
      end(owner: owner, session: session)
    }
    return .init(status: "stopped")
  }

  private func heartbeat(_ request: ServerScreenSharingRequest, sessionID: String) -> ServerScreenSharingReply {
    guard let owner = identity.owner(heartbeating: request, among: sessions), let session = sessions[owner],
      session.sessionID == sessionID
    else {
      return identity.ending(for: request)
        ?? .init(status: "stopped", message: "The live view ended on the host Mac.")
    }
    guard let activity = liveActivity(sessionID) else {
      end(owner: owner, session: session)
      return Self.stoppedControlling
    }

    session.expiresAt = dependencies.now() + Self.lifetime
    return .init(status: session.state, message: activity.windowNotice)
  }

  private func admit(_ request: ServerScreenSharingRequest, sessionID: String) async -> ServerScreenSharingReply {
    if let refusal = await identity.refusal(toStart: request) { return refusal }

    guard let owner = identity.begin(request, target: sessionID) else {
      return ScreenSharingStreamIdentity.updateNeeded
    }
    defer { identity.finish(request, as: owner) }
    return await start(request, owner: owner, sessionID: sessionID)
  }

  private func capabilities(_ request: ServerScreenSharingRequest, sessionID: String) -> ServerScreenSharingReply {
    guard dependencies.captureAccess() else { return Self.permissionRequired }
    guard let activity = liveActivity(sessionID) else { return Self.notControlling }
    var reply = ServerScreenSharingReply(
      status: "available", displays: [display(for: activity, target: request.displayId ?? "")])
    if dependencies.offersV2() { reply.engines = [ScreenSharingEngine.v2.rawValue] }
    return reply
  }

  private func start(
    _ request: ServerScreenSharingRequest, owner: Owner, sessionID: String
  ) async -> ServerScreenSharingReply {
    if let old = sessions[owner] { end(owner: owner, session: old) }
    guard sessions.count < Self.maximumSessions else {
      return .init(status: "busy", message: "Too many viewers are watching this agent.")
    }
    guard dependencies.captureAccess() else { return Self.permissionRequired }
    guard let media = ScreenSharingStreamMedia(request) else {
      return .init(status: "failed", message: "Invalid live view request.")
    }
    guard let activity = liveActivity(sessionID) else { return Self.notControlling }
    let size = dependencies.streamSize(activity.bridgeSessionID) ?? activity.windowFrame.size
    do {
      let peer = try await dependencies.makePeer(size, media)
      guard !isShutdown else {
        peer.close()
        return .init(status: "stopped")
      }
      guard identity.isStillStarting(request, as: owner) else {
        peer.close()
        return .init(status: "stopped")
      }
      if let raced = sessions[owner] { end(owner: owner, session: raced) }
      guard sessions.count < Self.maximumSessions else {
        peer.close()
        return .init(status: "busy", message: "Too many viewers are watching this agent.")
      }
      let session = Session(
        sessionID: sessionID, activity: activity, peer: peer, attempt: request.viewerId,
        token: identity.token(for: owner), expiresAt: dependencies.now() + Self.lifetime)
      return try await connect(session, activity: activity, owner: owner)
    } catch { return .init(status: "failed", message: error.localizedDescription) }
  }

  private func connect(
    _ session: Session, activity: ComputerUseLivePreview.Activity, owner: Owner
  ) async throws -> ServerScreenSharingReply {
    let peer = session.peer
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
      let grant = try await peer.start { [weak self, weak session] _ in
        guard let self, let session, self.sessions[owner] === session else { return }
        self.end(owner: owner, session: session)
      }
      guard !isShutdown, sessions[owner] === session else { throw CancellationError() }
      session.sink = dependencies.attach(session.bridgeSessionID, peer.sink)
      return .connecting(grant, message: activity.windowNotice, session: session.token)
    } catch {
      if sessions[owner] === session { end(owner: owner, session: session) } else { peer.close() }
      throw error
    }
  }

  func activityChanged() {
    for (owner, session) in sessions where liveActivity(session.sessionID) == nil {
      identity.remember(session, endedWith: Self.stoppedControlling)
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
    if let sink = session.sink { dependencies.detach(session.bridgeSessionID, sink) }
    session.sink = nil
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

  private static let permissionRequired = reply(
    "permission-required", "Allow Screen Recording for Codevisor on the host Mac.", .permissionMissing)
  private static let notControlling = reply(
    "unavailable", "The agent is not controlling an app right now.", .nothingToView)
  private static let stoppedControlling = reply(
    "stopped", "The agent stopped controlling the app.", .nothingToView)
  private static let updateNeeded = reply("unavailable", "Update Codevisor to use the live view.", .updateNeeded)

  private static func reply(
    _ status: String, _ message: String, _ reason: ServerScreenSharingReason
  ) -> ServerScreenSharingReply {
    var reply = ServerScreenSharingReply(status: status, message: message)
    reply.reason = reason
    return reply
  }
}
