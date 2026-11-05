import CodevisorNet
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
final class ScreenSharingV2Acceptor {
  static let shared = ScreenSharingV2Acceptor()

  private let router = ScreenSharingV2SessionRouter()
  private var endpoint: NetEndpointHandle?
  private var loop: Task<Void, Never>?

  func expect(
    _ endpointId: String, token: String, on endpoint: NetEndpointHandle
  ) -> ScreenSharingV2SessionRouter.Ticket {
    listen(on: endpoint)
    return router.expect(endpointId: endpointId, token: token)
  }

  func connection(
    _ ticket: ScreenSharingV2SessionRouter.Ticket, timeout: Duration
  ) async throws -> any ScreenSharingV2Connection {
    try await router.connection(ticket, timeout: timeout)
  }

  func connectLocally(token: String) -> (any ScreenSharingV2Connection)? {
    router.connectLocally(token: token)
  }

  private func listen(on endpoint: NetEndpointHandle) {
    guard self.endpoint !== endpoint || loop == nil else { return }

    loop?.cancel()
    self.endpoint = endpoint
    loop = Task { [weak self] in
      while true {
        let incoming: NetConnectionHandle?
        do {
          incoming = try await endpoint.accept()
        } catch {
          continue
        }
        guard let incoming, let self, !Task.isCancelled else { break }

        let router = self.router
        Task { await router.deliver(ScreenSharingV2IrohConnection(incoming)) }
      }
      guard let self, self.endpoint === endpoint else { return }

      self.loop = nil
      self.endpoint = nil
    }
  }
}
