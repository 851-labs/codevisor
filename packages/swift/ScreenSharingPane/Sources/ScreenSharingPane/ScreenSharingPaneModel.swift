import CodevisorClient
import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import ScreenSharing
import ScreenSharingV2

@MainActor
@Observable
public final class ScreenSharingPaneModel {
  public enum Phase: Equatable {
    case loading
    case connecting
    case viewing
    case reconnecting
    case failed(String)
  }

  public private(set) var displays: [ServerScreenSharingDisplay] = []
  public private(set) var displayId: String?
  public var keyboardShown = false
  public var connectionDetailsShown = false
  public private(set) var modifiers: ScreenSharingModifiers = []
  public var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?

  private(set) var stream: ScreenSharingStream?
  private var discoveryFailure: String?
  private var discoveryStep: ScreenSharingConnectStage?

  static let hiddenGrace: Duration = .seconds(60)

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let sponsor: ScreenSharingStreamSponsor
  @ObservationIgnored private var preferredDisplayId: String?
  @ObservationIgnored private var pointer = ScreenSharingPointerInput()
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var lingering: Task<Void, Never>?
  @ObservationIgnored private var discovery: Task<Void, Never>?
  @ObservationIgnored private var discoveryId: UUID?
  @ObservationIgnored private var discovered: (began: ContinuousClock.Instant, reply: ServerScreenSharingReply)?

  public convenience init(
    client: any CodevisorServerClienting, preferences: ScreenSharingPanePreferences?, workspaceId: UUID,
    paneId: UUID
  ) {
    self.init(
      preferences: preferences,
      sponsor: ScreenSharingStreamSponsor(workspaceId: workspaceId, paneId: paneId, client: client, v2: Self.engineV2())
    )
  }

  public nonisolated static let requestedChroma = ScreenSharingV2Chroma.subsampled

  private static func engineV2() -> ScreenSharingV2Connector {
    var connector = ScreenSharingV2Connector.live()
    connector.chroma = { requestedChroma }
    return connector
  }

  init(preferences: ScreenSharingPanePreferences?, sponsor: ScreenSharingStreamSponsor) {
    client = sponsor.client
    self.sponsor = sponsor
    preferredDisplayId = preferences?.preferredDisplayId
  }

  public static func enableEngineV2(environment: AppEnvironment) {
    ScreenSharingMediaEndpoint.shared.configure { [weak environment] in
      await environment?.screenSharingEndpoint(requestingLocalNetwork: false)
    }
  }

  public var phase: Phase {
    if let discoveryFailure { return .failed(discoveryFailure) }
    guard let stream else { return .loading }
    switch stream.phase {
    case .connecting: return .connecting
    case .streaming: return .viewing
    case .reconnecting: return .reconnecting
    case .failed(let message): return .failed(message)
    }
  }

  public var stillConnectingStep: String? {
    guard [.loading, .connecting].contains(phase) else { return nil }
    return (stream?.connectStep ?? discoveryStep)?.step(on: "the Mac")
  }

  public var selectedDisplay: ServerScreenSharingDisplay? {
    displays.first { $0.id == displayId }
  }

  public var control: ScreenSharingControlSession? { stream?.control }

  var session: (any ScreenSharingViewingSession)? { stream?.session }

  public var diagnostics: ScreenSharingViewerDiagnostics? { stream?.diagnostics }

  public func appeared() {
    guard !visible else { return }
    visible = true
    lingering?.cancel()
    lingering = nil
    if stream == nil, discovery == nil { discover() }
  }

  public func disappeared() {
    guard visible else { return }
    visible = false
    keyboardShown = false
    control?.release()
    guard stream != nil else { return }
    lingering = Task { [weak self] in
      guard (try? await Task.sleep(for: Self.hiddenGrace)) != nil else { return }
      guard let self, !self.visible else { return }
      self.stopStream()
    }
  }

  public func closed() {
    visible = false
    lingering?.cancel()
    discovery?.cancel()
    discovery = nil
    stopStream()
  }

  public func retry() {
    stopStream()
    discoveryFailure = nil
    discover()
  }

  public func applyPreferences(_ preferences: ScreenSharingPanePreferences) {
    guard let preferred = preferences.preferredDisplayId, preferred != displayId,
      displays.contains(where: { $0.id == preferred })
    else {
      preferredDisplayId = preferences.preferredDisplayId ?? preferredDisplayId
      return
    }
    preferredDisplayId = preferred
    connect(to: preferred)
  }

  public func select(displayId id: String) {
    guard id != displayId, displays.contains(where: { $0.id == id }) else { return }
    preferredDisplayId = id
    connect(to: id)
    onPreferencesChanged?(ScreenSharingPanePreferences(preferredDisplayId: id))
  }

  public func toggle(_ modifier: ScreenSharingModifiers) {
    modifiers.formSymmetricDifference(modifier)
  }

  public func type(_ text: String) {
    send(ScreenSharingKeyboard.type(text, modifiers: modifiers))
    modifiers = []
  }

  public func press(_ key: ScreenSharingKey) {
    send(ScreenSharingKeyboard.press(code: key.rawValue, modifiers: modifiers))
    modifiers = []
  }

  public func paste(_ text: String) {
    guard !text.isEmpty else { return }
    send(ScreenSharingKeyboard.type(text, modifiers: []))
  }

  func pressHardwareKey(usage: Int, modifiers flags: ScreenSharingModifiers) -> Bool {
    guard let code = ScreenSharingKeyboard.code(forHIDUsage: usage) else { return false }
    send(ScreenSharingKeyboard.press(code: code, modifiers: flags.union(modifiers)))
    modifiers = []
    return true
  }

  func tap(at pointer: ScreenSharingPointer, location: CGPoint, time: TimeInterval) {
    send(self.pointer.tap(at: pointer, location: location, time: time))
  }

  func secondaryClick(at pointer: ScreenSharingPointer) {
    send(self.pointer.secondaryClick(at: pointer))
  }

  func dragBegan(at pointer: ScreenSharingPointer) {
    send(self.pointer.dragBegan(at: pointer))
  }

  func dragMoved(to pointer: ScreenSharingPointer) {
    send(self.pointer.dragMoved(to: pointer))
  }

  func dragEnded(at pointer: ScreenSharingPointer) {
    send(self.pointer.dragEnded(at: pointer))
  }

  func scrolled(at pointer: ScreenSharingPointer, dx: Double, dy: Double) {
    send(self.pointer.scrolled(at: pointer, dx: dx, dy: dy))
  }

  func presentedFirstFrame() { stream?.presentedFirstFrame() }

  private func send(_ events: [ScreenSharingInputEvent]) {
    guard phase == .viewing, let control else { return }
    control.send(events)
  }

  private func discover() {
    discovery?.cancel()
    let began = sponsor.now()
    let id = UUID()
    discoveryId = id
    discoveryStep = nil
    discovery = Task { [weak self] in
      guard let self else { return }
      defer { self.endDiscovery(id) }
      do {
        let reply = try await self.capabilities(since: began, discovery: id)
        try Task.checkCancellation()
        if reply.provider == "vnc" {
          self.discoveryFailure = "Screen Sharing to this machine is only available on a Mac."
          return
        }
        guard reply.version == 1, ["available", "busy"].contains(reply.status), !reply.displays.isEmpty else {
          self.discoveryFailure = reply.message ?? "This Mac can't share its screen right now."
          return
        }
        self.displays = reply.displays
        self.discovered = (began, reply)
        let chosen = reply.displays.first { $0.id == self.preferredDisplayId } ?? reply.displays[0]
        if self.visible || self.stream == nil { self.connect(to: chosen.id) }
      } catch is CancellationError {
      } catch {
        self.discoveryFailure = ScreenSharingStream.message(for: error)
      }
    }
  }

  private func endDiscovery(_ id: UUID) {
    guard discoveryId == id else { return }
    discovery = nil
    discoveryStep = nil
  }

  private func capabilities(
    since began: ContinuousClock.Instant, discovery id: UUID
  ) async throws
    -> ServerScreenSharingReply
  {
    let request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: sponsor.workspaceId, paneId: sponsor.paneId, viewerId: UUID())
    let client = client
    let clock = sponsor.clock
    let now = sponsor.now
    let deadline: @Sendable () async throws -> Void = { [weak self] in
      try await clock.sleep(for: max(.zero, ScreenSharingConnectStage.stillConnectingAfter - (now() - began)))
      await self?.discoveryIsSlow(id)
      try await clock.sleep(for: max(.zero, ScreenSharingConnectStage.deadline - (now() - began)))
      if client.isReconnecting { try await clock.sleep(for: ScreenSharingConnectStage.reconnectingTunnelGrace) }
    }
    guard
      let reply = try await ScreenSharingRace.value(of: { try await client.screenSharing(request) }, before: deadline)
    else { throw ScreenSharingError.unavailable(ScreenSharingConnectStage.reachingHost.failure) }
    return reply
  }

  private func discoveryIsSlow(_ id: UUID) {
    guard discoveryId == id else { return }
    discoveryStep = .reachingHost
  }

  private func connect(to id: String) {
    stopStream()
    displayId = id
    let stream = ScreenSharingStream(displayId: id, sponsor: sponsor)
    self.stream = stream
    let fresh = discovered.flatMap { sponsor.now() - $0.began < ScreenSharingConnectStage.deadline ? $0 : nil }
    discovered = nil
    stream.start(since: fresh?.began, capabilities: fresh?.reply)
  }

  private func stopStream() {
    lingering?.cancel()
    lingering = nil
    stream?.stop()
    stream = nil
    pointer = ScreenSharingPointerInput()
  }
}
