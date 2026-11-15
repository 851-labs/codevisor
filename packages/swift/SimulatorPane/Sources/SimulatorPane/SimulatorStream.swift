import CoreGraphics
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection

@MainActor
@Observable
final class SimulatorStream: SimulatorConnection {
  static let unavailable = "This simulator can't be shown right now."

  @ObservationIgnored private let id = UUID()
  @ObservationIgnored private let pane: ScreenSharingLegacyIdentity
  @ObservationIgnored private let machineName: String
  @ObservationIgnored private let join: @MainActor () -> SimulatorSharedStream?
  @ObservationIgnored private let leave: @MainActor (SimulatorSharedStream) -> Void
  private var shared: SimulatorSharedStream?
  @ObservationIgnored private var surface: ScreenSharingSurface?
  private var isStarted = false
  @ObservationIgnored private var isVisible = false

  init(
    pane: ScreenSharingLegacyIdentity, machineName: String, join: @escaping @MainActor () -> SimulatorSharedStream?,
    leave: @escaping @MainActor (SimulatorSharedStream) -> Void
  ) {
    self.pane = pane
    self.machineName = machineName
    self.join = join
    self.leave = leave
  }

  var phase: SimulatorConnectionPhase {
    guard let shared else { return isStarted ? .failed(Self.unavailable) : .connecting }

    switch shared.connection.state {
    case .off, .connecting, .failed(.nothingToView): return .connecting
    case .live: return .streaming
    case .reconnecting: return .reconnecting
    case .failed(let reason): return .failed(reason.sentence(on: machineName))
    }
  }

  var isWaitingForTheSimulator: Bool {
    if case .failed(.nothingToView) = shared?.connection.state { true } else { false }
  }

  var state: ScreenSharingSimulatorState? { shared?.deviceState }

  var frameSize: CGSize? { shared?.frameSize }

  var source: SimulatorScreenSource? {
    guard let session = shared?.connection.session else { return nil }

    return .video(session.frames.tap(id), session.metrics)
  }

  func start() {
    isStarted = true
    guard shared == nil, let joined = join() else { return }

    shared = joined
    joined.panes.add(pane)
    surface = joined.connection.attach(.tab)
    surface?.setOnScreen(isVisible)
  }

  isolated deinit {
    part()
  }

  func stop() {
    isStarted = false
    part()
  }

  func setVisible(_ visible: Bool) {
    isVisible = visible
    if visible { rejoinIfEnded() }
    surface?.setOnScreen(visible)
  }

  func retry() {
    rejoinIfEnded()
    guard shared != nil else { return start() }

    surface?.retry()
  }

  func simulatorAppeared() {
    shared?.connection.targetAppeared()
  }

  @discardableResult
  func send(_ message: ScreenSharingSimulatorMessage) -> Bool { shared?.send(message) ?? false }

  func presented(frameSize size: CGSize) {
    guard let shared, shared.frameSize != size else { return }

    shared.frameSize = size
  }

  private func rejoinIfEnded() {
    guard isStarted, shared?.connection.isEnded == true else { return }

    part()
    start()
  }

  private func part() {
    guard let shared else { return }

    shared.connection.session?.frames.untap(id)
    surface?.detach()
    surface = nil
    self.shared = nil
    shared.panes.remove(pane)
    leave(shared)
  }
}
