import CodevisorCore
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection

extension ComputerUseLivePreview {
  public static let remoteUnavailable = "This live view can't be shown right now."

  public func makeRemoteViewer(
    chatSession id: UUID, source: ComputerUseRemotePreviewSource
  ) -> ComputerUseLivePreviewViewer {
    let target = ComputerUseStreamTarget.displayId(sessionID: id.uuidString)
    guard let connection = source.connection(target, ComputerUseRemotePreviewTiming.heartbeat) else {
      return ComputerUseLivePreviewViewer(title: "", phase: .stopped(Self.remoteUnavailable), onDetach: nil)
    }

    var preview: ComputerUseRemotePreview?
    let viewer = ComputerUseLivePreviewViewer(title: "", phase: .connecting) { preview?.detach() }
    preview = ComputerUseRemotePreview(
      viewer: viewer,
      dependencies: .init(
        connection: connection, machineName: source.machineName,
        isActive: { await source.isActive(target) },
        sleep: { try await Task.sleep(for: $0) },
        makeSurface: { session, tap in
          try? ComputerUseLivePreviewSurface(mailbox: session.frames.tap(tap), metrics: session.metrics)
        },
        end: { source.end(target) }))
    return viewer
  }

  public func remoteActivityIsActive(
    chatSession id: UUID, source: ComputerUseRemotePreviewSource
  ) async -> Bool? {
    await source.isActive(ComputerUseStreamTarget.displayId(sessionID: id.uuidString))
  }

  public static func remotePollInterval(prefersFastPolling: Bool) -> Duration {
    ComputerUseRemotePreviewTiming.pollInterval(prefersFastPolling: prefersFastPolling)
  }
}

@MainActor
final class ComputerUseRemotePreview {
  typealias Phase = ComputerUseLivePreviewViewer.Phase

  struct Dependencies {
    var connection: ScreenSharingConnection
    var machineName: String
    var isActive: @MainActor () async -> Bool?
    var sleep: @Sendable (Duration) async throws -> Void
    var makeSurface: @MainActor (any ScreenSharingViewingSession, UUID) -> ComputerUseLivePreviewSurface?
    var end: @MainActor () -> Void
  }

  private struct Snapshot {
    let state: ScreenSharingConnectionState
    let session: (any ScreenSharingViewingSession)?
    let title: String?
    let notice: String?
  }

  private let dependencies: Dependencies
  private let tap = UUID()
  private weak var viewer: ComputerUseLivePreviewViewer?
  private var surface: ScreenSharingSurface?
  private weak var shown: (any ScreenSharingViewingSession)?
  private var waiting: Task<Void, Never>?

  init(viewer: ComputerUseLivePreviewViewer, dependencies: Dependencies) {
    self.viewer = viewer
    self.dependencies = dependencies
    let surface = dependencies.connection.attach(.pictureInPicture)
    self.surface = surface
    surface.setOnScreen(true)
    follow()
  }

  var connection: ScreenSharingConnection { dependencies.connection }

  isolated deinit {
    detach()
  }

  func detach() {
    guard let surface else { return }

    self.surface = nil
    waiting?.cancel()
    waiting = nil
    shown?.frames.untap(tap)
    surface.detach()
    if connection.surfaces.isEmpty { dependencies.end() }
  }

  static func phase(of state: ScreenSharingConnectionState, on machine: String) -> Phase {
    switch state {
    case .off, .connecting: .connecting
    case .live: .live
    case .reconnecting: .reconnecting
    case .failed(.nothingToView): .searching
    case .failed(let reason): .stopped(reason.sentence(on: machine))
    }
  }

  private func follow() {
    guard surface != nil else { return }

    let connection = connection
    let snapshot = withObservationTracking {
      Snapshot(
        state: connection.state, session: connection.session, title: connection.displays.first?.name,
        notice: connection.hostNotice)
    } onChange: { [weak self] in
      Task { @MainActor in self?.follow() }
    }
    apply(snapshot)
  }

  private func apply(_ snapshot: Snapshot) {
    guard let viewer else { return }

    if let title = snapshot.title, viewer.title != title { viewer.update(title: title) }
    if viewer.notice != snapshot.notice { viewer.update(notice: snapshot.notice) }
    let phase = Self.phase(of: snapshot.state, on: dependencies.machineName)
    if viewer.phase != phase { enter(phase, on: viewer) }
    show(snapshot.session, in: viewer)
    waitForSomethingToView(Self.waits(in: snapshot.state))
  }

  private func enter(_ phase: Phase, on viewer: ComputerUseLivePreviewViewer) {
    viewer.update(phase: phase)
    let target = connection.target ?? ""
    Log.computerUse.notice("Live view \(target, privacy: .public): \(String(describing: phase), privacy: .public)")
  }

  static func waits(in state: ScreenSharingConnectionState) -> Bool {
    switch state {
    case .failed(.nothingToView), .failed(.cantReach): true
    case .off, .connecting, .live, .reconnecting, .failed: false
    }
  }

  private func show(_ session: (any ScreenSharingViewingSession)?, in viewer: ComputerUseLivePreviewViewer) {
    guard session !== shown else { return }

    shown?.frames.untap(tap)
    shown = session
    viewer.install(session.flatMap { dependencies.makeSurface($0, tap) })
  }

  private func somethingToView() {
    guard case .failed(.nothingToView) = connection.state else {
      surface?.retry()
      return
    }

    connection.targetAppeared()
  }

  private func waitForSomethingToView(_ isWaiting: Bool) {
    guard isWaiting else {
      waiting?.cancel()
      waiting = nil
      return
    }
    guard waiting == nil else { return }

    waiting = Task { [weak self] in await self?.pollUntilThereIsSomethingToView() }
  }

  private func pollUntilThereIsSomethingToView() async {
    while !Task.isCancelled {
      let fast = viewer?.prefersFastPolling ?? false
      guard
        (try? await dependencies.sleep(ComputerUseRemotePreviewTiming.pollInterval(prefersFastPolling: fast)))
          != nil, !Task.isCancelled
      else { return }

      guard await dependencies.isActive() == true, !Task.isCancelled else { continue }

      waiting = nil
      somethingToView()
      return
    }
  }
}
