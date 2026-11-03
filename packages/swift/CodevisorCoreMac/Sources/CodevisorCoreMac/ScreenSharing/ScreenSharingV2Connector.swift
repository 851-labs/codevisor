import CodevisorClient
import CodevisorNet
import Foundation
import ScreenSharing
import ScreenSharingV2

@MainActor
protocol NativeScreenSharingV2Session: ScreenSharingViewingSession {
  func start(token: String) async throws
}

extension ScreenSharingV2ViewingSession: NativeScreenSharingV2Session {}

struct ScreenSharingV2Connector {
  var address: @MainActor () async -> ServerScreenSharingMediaAddress?
  var connect: @MainActor (ServerScreenSharingMediaGrant) async throws -> any NativeScreenSharingV2Session

  static let connectTimeout: Duration = .seconds(15)

  @MainActor
  static func live(endpoint: ScreenSharingMediaEndpoint = .shared) -> Self {
    let handle = HandleBox()
    return Self(
      address: {
        guard let ready = await endpoint.ready() else { return nil }
        handle.value = ready
        return ScreenSharingMediaEndpoint.address(of: ready)
      },
      connect: { grant in
        guard let ready = handle.value else { throw ScreenSharingError.unavailable("No screen-sharing endpoint.") }
        let cancel = NetCancelToken()
        let timeout = Task {
          try await Task.sleep(for: connectTimeout)
          cancel.cancel()
        }
        defer { timeout.cancel() }
        let connection = try await withTaskCancellationHandler {
          try await ready.connect(
            addr: ScreenSharingMediaEndpoint.tunnelAddress(grant.address), alpn: mediaAlpn(), cancel: cancel)
        } onCancel: {
          cancel.cancel()
        }
        return ScreenSharingV2ViewingSession(connection: ScreenSharingV2IrohConnection(connection))
      })
  }

  @MainActor
  private final class HandleBox {
    var value: NetEndpointHandle?
  }
}
