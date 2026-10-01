import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

extension ComputerUseLivePreview {
  /// A viewer of the window a chat's agent controls on another Mac. It
  /// finds the agent's activity by polling the host, connects over the
  /// screen-sharing WebRTC path, and reconnects when the agent resumes.
  /// Call `detach()`; that also stops the host-side stream.
  public func makeRemoteViewer(
    chatSession id: UUID,
    client: any CodevisorServerClienting,
    workspaceId: UUID,
    paneId: UUID
  ) -> ComputerUseLivePreviewViewer {
    let connection = ComputerUseRemotePreviewConnection(
      chatSessionID: id, client: client, workspaceId: workspaceId, paneId: paneId)
    let viewer = ComputerUseLivePreviewViewer(title: "", phase: .searching) { connection.cancel() }
    connection.start(viewer: viewer)
    return viewer
  }

  /// Whether the agent of a chat on another Mac is controlling an app right
  /// now, asked without streaming it: nil when the host can't say (offline,
  /// no permission, an error). An idle agent counts as not controlling.
  public func remoteActivityIsActive(
    chatSession id: UUID,
    client: any CodevisorServerClienting,
    workspaceId: UUID,
    paneId: UUID
  ) async -> Bool? {
    let target = ComputerUseStreamTarget.displayId(sessionID: id.uuidString)
    let request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: workspaceId, paneId: paneId, viewerId: UUID(), displayId: target)
    guard let reply = try? await client.screenSharing(request) else { return nil }
    return Self.remoteActivityIsActive(reply: reply, target: target)
  }

  /// How often to ask a host about its agent: often while the chat's turn runs.
  public static func remotePollInterval(prefersFastPolling: Bool) -> Duration {
    ComputerUseRemotePreviewTiming.pollInterval(prefersFastPolling: prefersFastPolling)
  }

  /// Reads a capabilities reply: the host answers "unavailable" when the
  /// agent isn't controlling an app. Other refusals say nothing about it.
  static func remoteActivityIsActive(reply: ServerScreenSharingReply, target: String) -> Bool? {
    guard reply.version == 1 else { return nil }
    switch reply.status {
    case "available", "busy": return reply.displays.contains { $0.id == target }
    case "unavailable": return false
    default: return nil
    }
  }
}

/// Timing of the remote viewer's search for an active agent.
enum ComputerUseRemotePreviewTiming {
  /// While the chat's turn is running an agent may start controlling an
  /// app at any moment.
  static let activePoll: Duration = .seconds(3)
  static let quietPoll: Duration = .seconds(15)
  /// How long an ended stream stays on screen with its reason.
  static let endedLinger: Duration = .seconds(2)

  static func pollInterval(prefersFastPolling: Bool) -> Duration {
    prefersFastPolling ? activePoll : quietPoll
  }
}

@MainActor
final class ComputerUseRemotePreviewConnection {
  private let target: String
  private var backend: ScreenSharingViewerBackend?
  private var latestSurface: ComputerUseLivePreviewSurface?
  private weak var viewer: ComputerUseLivePreviewViewer?
  private var task: Task<Void, Never>?

  init(
    chatSessionID: UUID,
    client: any CodevisorServerClienting,
    workspaceId: UUID,
    paneId: UUID
  ) {
    target = ComputerUseStreamTarget.displayId(sessionID: chatSessionID.uuidString)
    backend = .native(
      client: client, workspaceId: workspaceId, paneId: paneId,
      sleep: { try await Task.sleep(for: $0) },
      makeSession: { try await ScreenSharingReceiver.process(connectivity: $0) },
      makeSurface: { [weak self] session in
        let surface = try ComputerUseLivePreviewSurface(mailbox: session.frames, metrics: session.metrics)
        self?.latestSurface = surface
        return surface
      },
      target: target)
  }

  func start(viewer: ComputerUseLivePreviewViewer) {
    self.viewer = viewer
    task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.cycle()
        guard !Task.isCancelled, let viewer = self.viewer else { return }
        try? await Task.sleep(
          for: ComputerUseRemotePreviewTiming.pollInterval(prefersFastPolling: viewer.prefersFastPolling))
      }
    }
  }

  /// Cancelling ends the stream, which sends the host an authenticated stop.
  func cancel() {
    task?.cancel()
    task = nil
  }

  private func cycle() async {
    guard let backend, let viewer else { return }
    let displays: [ServerScreenSharingDisplay]
    do {
      displays = try await backend.discover()
    } catch {
      viewer.update(phase: .searching)
      return
    }
    guard !Task.isCancelled, let display = displays.first(where: { $0.id == target }) else {
      viewer.update(phase: .searching)
      return
    }
    viewer.update(title: display.name)
    viewer.update(phase: .connecting)
    var ended: String?
    for await event in await backend.connect(target) {
      switch event {
      case .opened:
        viewer.install(latestSurface)
      case .ready:
        viewer.update(phase: .live)
      case .reconnecting:
        viewer.update(phase: .reconnecting)
      case .hostNotice:
        break
      case .ended(let message):
        ended = message
      }
    }
    guard !Task.isCancelled else { return }
    if let ended {
      viewer.update(phase: .stopped(ended))
      try? await Task.sleep(for: ComputerUseRemotePreviewTiming.endedLinger)
    }
    viewer.install(nil)
    viewer.update(phase: .searching)
  }
}
