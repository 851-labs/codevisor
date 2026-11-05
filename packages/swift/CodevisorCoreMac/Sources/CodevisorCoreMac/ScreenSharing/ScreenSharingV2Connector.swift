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

  @MainActor
  static func live(endpoint: ScreenSharingMediaEndpoint = .shared) -> Self {
    Self(address: { await endpoint.viewerAddress() }, connect: { try await endpoint.connectViewer(to: $0) })
  }
}

extension ScreenSharingMediaEndpoint {
  static let connectTimeout: Duration = .seconds(15)

  public func viewerAddress() async -> ServerScreenSharingMediaAddress? {
    guard let ready = await ready() else { return nil }

    viewerHandle = ready
    return Self.address(of: ready)
  }

  public func connectViewer(to grant: ServerScreenSharingMediaGrant) async throws -> ScreenSharingV2ViewingSession {
    let handle: NetEndpointHandle?
    if let viewerHandle { handle = viewerHandle } else { handle = await ready() }
    guard let ready = handle else { throw ScreenSharingError.unavailable("No screen-sharing endpoint.") }
    guard grant.endpointId != ready.endpointId() else {
      guard let local = ScreenSharingV2Acceptor.shared.connectLocally(token: grant.token) else {
        throw ScreenSharingError.unavailable("This Mac's screen-sharing session ended.")
      }

      return ScreenSharingV2ViewingSession(connection: local)
    }

    let cancel = NetCancelToken()
    let timeout = Task {
      try await Task.sleep(for: Self.connectTimeout)
      cancel.cancel()
    }
    defer { timeout.cancel() }
    let connection = try await withTaskCancellationHandler {
      try await ready.connect(addr: Self.tunnelAddress(grant.address), alpn: mediaAlpn(), cancel: cancel)
    } onCancel: {
      cancel.cancel()
    }
    return ScreenSharingV2ViewingSession(connection: ScreenSharingV2IrohConnection(connection))
  }
}
