import CodevisorClient
import CodevisorNet
import Foundation
import ScreenSharing

@MainActor
public protocol ScreenSharingV2StartableSession: ScreenSharingViewingSession {
  var presentsTiles: Bool { get set }
  func start(token: String) async throws
}

extension ScreenSharingV2ViewingSession: ScreenSharingV2StartableSession {}

public struct ScreenSharingV2Connector {
  public typealias ConnectLocally = @MainActor (_ token: String) -> (any ScreenSharingV2Connection)?

  public var address: @MainActor () async -> ServerScreenSharingMediaAddress?
  public var connect: @MainActor (ServerScreenSharingMediaGrant) async throws -> any ScreenSharingV2StartableSession
  public var chroma: @Sendable () async -> ScreenSharingV2Chroma

  public init(
    address: @escaping @MainActor () async -> ServerScreenSharingMediaAddress?,
    connect: @escaping @MainActor (ServerScreenSharingMediaGrant) async throws -> any ScreenSharingV2StartableSession,
    chroma: @escaping @Sendable () async -> ScreenSharingV2Chroma = { .full }
  ) {
    self.address = address
    self.connect = connect
    self.chroma = chroma
  }

  @MainActor
  public static func live(
    endpoint: ScreenSharingMediaEndpoint = .shared, connectLocally: @escaping ConnectLocally = { _ in nil }
  ) -> Self {
    Self(
      address: { await endpoint.viewerAddress() },
      connect: { try await endpoint.connectViewer(to: $0, locally: connectLocally) },
      chroma: { await Task.detached { ScreenSharingV2Chroma.decodable }.value })
  }
}

extension ScreenSharingMediaEndpoint {
  public static let connectTimeout: Duration = .seconds(15)

  public func viewerAddress() async -> ServerScreenSharingMediaAddress? {
    guard let ready = await ready() else { return nil }

    viewerHandle = ready
    return Self.address(of: ready)
  }

  public func connectViewer(
    to grant: ServerScreenSharingMediaGrant, locally connectLocally: ScreenSharingV2Connector.ConnectLocally
  ) async throws -> ScreenSharingV2ViewingSession {
    let handle: NetEndpointHandle?
    if let viewerHandle { handle = viewerHandle } else { handle = await ready() }
    guard let ready = handle else { throw ScreenSharingError.unavailable("No screen-sharing endpoint.") }
    guard grant.endpointId != ready.endpointId() else {
      guard let local = connectLocally(grant.token) else {
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
