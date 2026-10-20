import CodevisorCore
import Foundation
import ScreenSharing
import ScreenSharingWebRTC

extension ComputerUseLivePreview {
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

  public static func remotePollInterval(prefersFastPolling: Bool) -> Duration {
    ComputerUseRemotePreviewTiming.pollInterval(prefersFastPolling: prefersFastPolling)
  }

  static func remoteActivityIsActive(reply: ServerScreenSharingReply, target: String) -> Bool? {
    guard reply.version == 1 else { return nil }
    switch reply.status {
    case "available", "busy": return reply.displays.contains { $0.id == target }
    case "unavailable": return false
    default: return nil
    }
  }
}

enum ComputerUseRemotePreviewTiming {
  static let activePoll: Duration = .seconds(3)
  static let quietPoll: Duration = .seconds(15)
  static let heartbeat: Duration = .seconds(2)

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
      target: target,
      heartbeatInterval: ComputerUseRemotePreviewTiming.heartbeat)
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
      case .hostNotice(let notice):
        viewer.update(notice: notice)
      case .elsewhere:
        break
      case .ended(let message):
        ended = message
      }
    }
    guard !Task.isCancelled else { return }
    if let ended {
      Log.computerUse.notice("Live view \(self.target, privacy: .public) ended: \(ended, privacy: .public)")
      viewer.update(phase: .stopped(ended))
    }
    viewer.install(nil)
    viewer.update(notice: nil)
    viewer.update(phase: .searching)
  }
}
