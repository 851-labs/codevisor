import ComposableArchitecture
import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class ScreenSharingDesktopControl {
  typealias Mode = ScreenSharingViewer.InteractionMode

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")

  private(set) var controller: UUID?
  private(set) var mode: Mode
  private var lease: StoreOf<ControlLease>?
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var endpoint: ScreenSharingViewerEndpoint?
  @ObservationIgnored private var events: Task<Void, Never>?

  var status: ScreenSharingControlStatus {
    lease.map { ScreenSharingControlStatus(phase: $0.phase, message: $0.message) } ?? ScreenSharingControlStatus()
  }

  init(mode: Mode, clock: any Clock<Duration>) {
    self.mode = mode
    self.clock = clock
  }

  func attach(_ endpoint: ScreenSharingViewerEndpoint?) {
    detach()
    self.endpoint = endpoint
    guard let endpoint else { return }

    let lease = Store(initialState: ControlLease.State(endpoint: endpoint.id)) {
      ControlLease()
    } withDependencies: { [clock] in
      $0.continuousClock = clock
      $0.uuid = UUIDGenerator { UUID() }
      $0[ScreenSharingEndpointClient.self] = .liveValue
    }
    self.lease = lease
    events = Task { [weak lease] in
      for await event in endpoint.controlEvents() { lease?.send(.event(event)) }
    }
    endpoint.moveInput(to: controller)
    if controller != nil { ask() }
  }

  func take(_ id: UUID) {
    guard mode == .control else { return }

    if controller != id { note("keyboard and mouse go to surface \(id.uuidString.prefix(4))") }
    controller = id
    endpoint?.moveInput(to: id)
    ask()
  }

  func offer(_ id: UUID) {
    guard controller == nil else { return }

    take(id)
  }

  func drop(_ id: UUID) {
    guard controller == id else { return }

    note("surface \(id.uuidString.prefix(4)) left; nobody has the keyboard and mouse")
    controller = nil
    endpoint?.moveInput(to: nil)
    lease?.send(.suspended)
  }

  func setMode(_ mode: Mode, from id: UUID?) {
    note("mode set to \(mode)")
    self.mode = mode
    guard mode == .view else {
      if let id { take(id) }
      return
    }
    controller = nil
    endpoint?.moveInput(to: nil)
    lease?.send(.controlReleased(reason: nil))
  }

  private func note(_ event: String) {
    Self.logger.notice("Control: \(event, privacy: .public)")
  }

  private func ask() {
    lease?.send(.controlRequested)
  }

  private func detach() {
    events?.cancel()
    events = nil
    lease = nil
    endpoint = nil
  }
}
