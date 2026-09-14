import AppKit
import CodevisorCore
import Foundation
import Observation

@MainActor
@Observable
public final class ScreenSharingViewerModel {
  public enum Phase: Equatable { case idle, loading, ready, connecting, reconnecting, viewing, suspended, failed }
  public private(set) var phase: Phase = .idle
  public private(set) var message: String?
  public private(set) var displays: [ServerScreenSharingDisplay] = []
  public private(set) var selectedDisplayId: String?
  public private(set) var preferences: ScreenSharingPanePreferences
  public private(set) var videoView: NSView?
  public var control: ScreenSharingViewerControl? { endpoint?.control }
  public var clipboard: ScreenSharingViewerClipboard? { endpoint?.clipboard }
  public var diagnostics: ScreenSharingViewerDiagnostics? { endpoint?.diagnostics }
  @ObservationIgnored public var onFocusChanged: ((Bool) -> Void)?
  @ObservationIgnored public var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?
  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let workspaceId: UUID
  @ObservationIgnored private let paneId: UUID
  @ObservationIgnored private let makePeer: (ServerScreenSharingConnectivity?) throws -> any ScreenSharingViewingPeer
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var endpoint: (any ScreenSharingViewingPeer)?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var wantsConnection = false
  @ObservationIgnored private var activeViewerId: UUID?

  public convenience init(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    preferences: ScreenSharingPanePreferences = .init()
  ) {
    self.init(
      client: client, workspaceId: workspaceId, paneId: paneId, preferences: preferences,
      makePeer: { try NativeScreenSharingViewingPeer(connectivity: $0) }, sleep: { try await Task.sleep(for: $0) })
  }

  init(
    client: any CodevisorServerClienting, workspaceId: UUID, paneId: UUID,
    preferences: ScreenSharingPanePreferences = .init(),
    makePeer: @escaping (ServerScreenSharingConnectivity?) throws -> any ScreenSharingViewingPeer,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) {
    self.client = client; self.workspaceId = workspaceId; self.paneId = paneId
    self.preferences = preferences; self.makePeer = makePeer; self.sleep = sleep
  }

  public func setVisible(_ visible: Bool) {
    guard self.visible != visible else { return }
    self.visible = visible
    if visible { refresh() } else { cancel(); phase = .suspended }
  }

  public func refresh() {
    guard visible else { return }
    let previous = cancel()
    let generation = generation
    phase = .loading; message = nil
    task = Task { [self] in
      await previous?.value
      guard isCurrent(generation) else { return }
      do {
        let reply = try await client.screenSharing(request(.capabilities, viewerId: UUID()))
        guard isCurrent(generation) else { return }
        guard reply.version == 1, ["available", "busy"].contains(reply.status) else {
          throw ViewerError(reply.message ?? "Screen Sharing is unavailable on this Mac.")
        }
        displays = reply.displays
        if let preferred = preferences.preferredDisplayId {
          selectedDisplayId = displays.first(where: { $0.id == preferred })?.id
          if selectedDisplayId == nil {
            throw ViewerError("The selected display is unavailable. Choose another display to connect.")
          }
        } else {
          selectedDisplayId = displays.first?.id
        }
        guard selectedDisplayId != nil else { throw ViewerError("No displays are available on this Mac.") }
        phase = .ready
        if wantsConnection { await runConnection(generation: generation) }
      } catch { if isCurrent(generation) { phase = .failed; message = serverErrorMessage(error) } }
    }
  }

  public func selectDisplay(_ id: String) {
    guard displays.contains(where: { $0.id == id }) else { return }
    preferences.preferredDisplayId = id
    selectedDisplayId = id
    onPreferencesChanged?(preferences)
    if wantsConnection { connect() } else { message = nil; phase = .ready }
  }

  public func setFitToWindow(_ fit: Bool) {
    preferences.fitToWindow = fit
    endpoint?.fit(fit)
    onPreferencesChanged?(preferences)
  }

  /// Apply a registry update without replacing the live surface or echoing
  /// the write. A display change from another client requires a new Connect.
  public func applyPreferences(_ preferences: ScreenSharingPanePreferences) {
    guard self.preferences != preferences else { return }
    let displayChanged = self.preferences.preferredDisplayId != preferences.preferredDisplayId
    self.preferences = preferences
    endpoint?.fit(preferences.fitToWindow)
    if displayChanged { wantsConnection = false; refresh() }
  }

  public func connect() {
    guard visible, selectedDisplayId != nil else { return }
    preferences.preferredDisplayId = selectedDisplayId
    onPreferencesChanged?(preferences)
    wantsConnection = true
    let previous = cancel()
    let generation = generation
    phase = .connecting; message = nil
    task = Task { [self] in
      await previous?.value
      guard isCurrent(generation) else { return }
      await runConnection(generation: generation)
    }
  }

  public func disconnect() {
    wantsConnection = false
    cancel()
    phase = visible ? .ready : .suspended
    message = nil
  }

  public func close() async {
    wantsConnection = false; visible = false; let pending = cancel(); phase = .suspended; await pending?.value
  }

  @discardableResult
  private func cancel() -> Task<Void, Never>? {
    generation += 1
    let previous = task
    previous?.cancel()
    endpoint?.close()
    endpoint = nil; videoView = nil
    guard let viewerId = activeViewerId else { return previous }
    activeViewerId = nil
    let stop = request(.stop, viewerId: viewerId)
    let client = client
    return Task {
      await previous?.value
      _ = try? await client.screenSharing(stop)
    }
  }

  private func runConnection(generation: Int, viewerId: UUID = UUID(), restarts: Int = 0) async {
    guard let display = selectedDisplayId else { return }
    activeViewerId = viewerId
    var started = false
    var handingOff = false
    var peer: (any ScreenSharingViewingPeer)?
    do {
      // Fetch fresh short-lived relay credentials at connection time. The
      // display picker may have been left open much longer than their lifetime.
      let capabilities = try await client.screenSharing(request(.capabilities, viewerId: viewerId))
      try requireCurrent(generation)
      guard capabilities.version == 1, ["available", "busy"].contains(capabilities.status) else {
        throw ViewerError(capabilities.message ?? "Screen Sharing is unavailable on this Mac.")
      }
      let created = try makePeer(capabilities.connectivity)
      peer = created; endpoint = created; videoView = created.view
      created.fit(preferences.fitToWindow)
      created.onFocusChanged = { [weak self] in self?.onFocusChanged?($0) }
      phase = restarts == 0 ? .connecting : .reconnecting
      created.onReady = { [weak self] in
        guard let self, self.isCurrent(generation), [.connecting, .reconnecting].contains(self.phase) else { return }
        self.phase = .viewing
        self.message = nil
      }
      created.onConnectionChanged = { [weak self] state in
        guard let self, self.isCurrent(generation), ["failed", "disconnected", "closed"].contains(state) else { return }
        if self.phase == .viewing, restarts < 3, state != "closed" {
          handingOff = true
          self.recover(generation: generation, viewerId: viewerId, restarts: restarts + 1)
          return
        }
        self.phase = .failed
        self.message = "The screen-sharing connection ended. Reconnect to continue."
        self.task?.cancel()
      }
      let offer = try await created.offer()
      try requireCurrent(generation)
      started = true
      let reply = try await client.screenSharing(
        request(
          restarts == 0 ? .start : .restart,
          viewerId: viewerId, displayId: display, offer: offer))
      try requireCurrent(generation)
      guard reply.version == 1, reply.status == "connecting", let answer = reply.answer else {
        throw ViewerError(reply.message ?? "This Mac cannot start screen sharing right now.")
      }
      try await created.accept(answer)
      try requireCurrent(generation)
      var heartbeatsBeforeVideo = 0
      while isCurrent(generation) {
        try await sleep(.seconds(8))
        try requireCurrent(generation)
        let reply = try await client.screenSharing(request(.heartbeat, viewerId: viewerId))
        try requireCurrent(generation)
        guard reply.version == 1, ["connecting", "viewing"].contains(reply.status) else {
          throw ViewerError(reply.message ?? "Screen sharing ended on the host Mac.")
        }
        if let failure = created.failure { throw ViewerError(failure) }
        if phase == .connecting || phase == .reconnecting {
          heartbeatsBeforeVideo += 1
          guard heartbeatsBeforeVideo < 3 else {
            throw ViewerError(
              "No video arrived. Check the connection between these Macs or the configured relay, then retry.")
          }
        }
      }
    } catch {
      if isCurrent(generation), !isTaskCancellation(error) { phase = .failed; message = serverErrorMessage(error) }
    }
    peer?.close()
    if started, !handingOff {
      // URLSession inherits task cancellation. Cleanup needs a fresh task so
      // hiding the tab can still deliver the authenticated stop request.
      let stop = request(.stop, viewerId: viewerId)
      let client = client
      await Task { _ = try? await client.screenSharing(stop) }.value
    }
    if generation == self.generation { endpoint = nil; videoView = nil; activeViewerId = nil }
  }

  private func recover(generation: Int, viewerId: UUID, restarts: Int) {
    guard isCurrent(generation), visible, wantsConnection else { return }
    let previous = task
    self.generation += 1
    let next = self.generation
    previous?.cancel()
    endpoint?.close()  // Releases every held input and discards the old render mailbox.
    endpoint = nil; videoView = nil
    phase = .reconnecting
    message = "Reconnecting to this Mac…"
    task = Task { [self] in
      await previous?.value
      guard isCurrent(next) else { return }
      await runConnection(generation: next, viewerId: viewerId, restarts: restarts)
    }
  }

  private func isCurrent(_ generation: Int) -> Bool { visible && generation == self.generation && !Task.isCancelled }
  private func requireCurrent(_ generation: Int) throws { if !isCurrent(generation) { throw CancellationError() } }
  private func request(
    _ operation: ServerScreenSharingRequest.Operation, viewerId: UUID,
    displayId: String? = nil, offer: String? = nil
  ) -> ServerScreenSharingRequest {
    .init(
      operation: operation, workspaceId: workspaceId, paneId: paneId, viewerId: viewerId, displayId: displayId,
      offer: offer)
  }
  private struct ViewerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}
