import CoreGraphics
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection

@MainActor
@Observable
final class SimulatorSharedStream {
  let connection: ScreenSharingConnection
  private(set) var deviceState: ScreenSharingSimulatorState?
  var frameSize: CGSize?

  @ObservationIgnored let panes: SimulatorAttachedPanes
  @ObservationIgnored private weak var bound: (any ScreenSharingSimulatorSession)?

  init(connection: ScreenSharingConnection, panes: SimulatorAttachedPanes) {
    self.connection = connection
    self.panes = panes
    connection.onSessionOpened = { [weak self] in self?.bind($0 as? any ScreenSharingSimulatorSession) }
    bind(connection.session as? any ScreenSharingSimulatorSession)
  }

  @discardableResult
  func send(_ message: ScreenSharingSimulatorMessage) -> Bool {
    guard let simulator = bound?.simulator, simulator.isAvailable else { return false }

    return simulator.send(message)
  }

  private func bind(_ session: (any ScreenSharingSimulatorSession)?) {
    guard session !== bound else { return }

    bound?.simulator.onMessage = nil
    bound = session
    session?.simulator.onMessage = { [weak self] message in
      guard case .state(let state) = message else { return }

      self?.deviceState = state
    }
  }
}
