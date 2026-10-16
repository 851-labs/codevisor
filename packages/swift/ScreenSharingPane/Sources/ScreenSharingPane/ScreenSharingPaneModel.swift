import CodevisorClient
import CodevisorCloud
import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import ScreenSharing
import ScreenSharingWebRTC

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
  public private(set) var modifiers: ScreenSharingModifiers = []
  public var onPreferencesChanged: ((ScreenSharingPanePreferences) -> Void)?

  private(set) var stream: ScreenSharingStream?
  private var discoveryFailure: String?

  static let hiddenGrace: Duration = .seconds(60)

  @ObservationIgnored private let client: any CodevisorServerClienting
  @ObservationIgnored private let sponsor: ScreenSharingStreamSponsor
  @ObservationIgnored private var preferredDisplayId: String?
  @ObservationIgnored private var pointer = ScreenSharingPointerInput()
  @ObservationIgnored private var visible = false
  @ObservationIgnored private var lingering: Task<Void, Never>?
  @ObservationIgnored private var discovery: Task<Void, Never>?

  public init(
    client: any CodevisorServerClienting, preferences: ScreenSharingPanePreferences?, workspaceId: UUID,
    paneId: UUID, openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)? = nil
  ) {
    self.client = client
    sponsor = ScreenSharingStreamSponsor(
      workspaceId: workspaceId, paneId: paneId, client: client, openTunnel: openTunnel)
    preferredDisplayId = preferences?.preferredDisplayId
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

  public var selectedDisplay: ServerScreenSharingDisplay? {
    displays.first { $0.id == displayId }
  }

  public var control: ScreenSharingControlSession? { stream?.control }

  var receiver: ScreenSharingReceiver? { stream?.receiver }

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
    discovery = Task { [weak self] in
      guard let self else { return }
      defer { self.discovery = nil }
      do {
        let reply = try await self.client.screenSharing(
          ServerScreenSharingRequest(
            operation: .capabilities, workspaceId: self.sponsor.workspaceId, paneId: self.sponsor.paneId,
            viewerId: UUID()))
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
        let chosen = reply.displays.first { $0.id == self.preferredDisplayId } ?? reply.displays[0]
        if self.visible || self.stream == nil { self.connect(to: chosen.id) }
      } catch is CancellationError {
      } catch {
        self.discoveryFailure = ScreenSharingStream.message(for: error)
      }
    }
  }

  private func connect(to id: String) {
    stopStream()
    displayId = id
    let stream = ScreenSharingStream(displayId: id, sponsor: sponsor)
    self.stream = stream
    stream.start()
  }

  private func stopStream() {
    lingering?.cancel()
    lingering = nil
    stream?.stop()
    stream = nil
    pointer = ScreenSharingPointerInput()
  }
}
