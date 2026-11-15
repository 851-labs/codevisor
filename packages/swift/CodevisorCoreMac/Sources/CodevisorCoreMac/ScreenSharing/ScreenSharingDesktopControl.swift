import ComposableArchitecture
import Foundation
import Observation

@MainActor
@Observable
final class ScreenSharingDesktopControl {
  typealias Mode = ScreenSharingViewer.InteractionMode

  private(set) var controller: UUID?
  private(set) var status = ScreenSharingControlStatus()
  private(set) var mode: Mode
  @ObservationIgnored private let clock: any Clock<Duration>
  @ObservationIgnored private var endpoint: ScreenSharingViewerEndpoint?
  @ObservationIgnored private var lease: StoreOf<ControlLease>?
  @ObservationIgnored private var events: Task<Void, Never>?
  @ObservationIgnored private var following: ObserveToken?

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
    following = observe { [weak self] in
      self?.status = ScreenSharingControlStatus(phase: lease.phase, message: lease.message)
    }
    events = Task { [weak lease] in
      for await event in endpoint.controlEvents() { lease?.send(.event(event)) }
    }
    endpoint.moveInput(to: controller)
    if controller != nil { ask() }
  }

  func take(_ id: UUID) {
    controller = id
    endpoint?.moveInput(to: id)
    ask()
  }

  func offer(_ id: UUID) {
    guard controller == nil, mode == .control else { return }

    take(id)
  }

  func drop(_ id: UUID) {
    guard controller == id else { return }

    controller = nil
    endpoint?.moveInput(to: nil)
    lease?.send(.suspended)
  }

  func setMode(_ mode: Mode, from id: UUID?) {
    self.mode = mode
    guard mode == .view else {
      if let id { take(id) }
      return
    }
    endpoint?.moveInput(to: nil)
    lease?.send(.controlReleased(reason: nil))
  }

  private func ask() {
    guard mode == .control else { return }

    lease?.send(.controlRequested)
  }

  private func detach() {
    events?.cancel()
    events = nil
    following = nil
    lease = nil
    endpoint = nil
    status = ScreenSharingControlStatus()
  }
}
