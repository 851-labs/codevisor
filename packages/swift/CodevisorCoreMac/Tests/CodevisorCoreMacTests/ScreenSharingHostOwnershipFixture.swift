import CodevisorClient
import CodevisorNet
import CoreGraphics
import Foundation
import ScreenSharingV2

@testable import CodevisorCoreMac

@MainActor
final class ScreenSharingHostOwnershipFixture {
  nonisolated static let main = ServerScreenSharingDisplay(
    id: "main", name: "Built-in Display", width: 1280, height: 720)
  nonisolated static let side = ServerScreenSharingDisplay(id: "side", name: "Side Display", width: 1280, height: 720)
  nonisolated static let hostVirtual = ServerScreenSharingDisplay(
    id: "virtual", name: "Codevisor Screen Sharing", width: 1280, height: 720)

  var displays = [ScreenSharingHostOwnershipFixture.main]
  var listDisplays: (() async throws -> [ServerScreenSharingDisplay])?
  var allowsCapture = true
  let workspace = NotificationCenter()
  let media = ScreenSharingMediaEndpoint()
  private(set) var host: ScreenSharingHostService!
  private var endpoint: NetEndpointHandle?

  static func run(_ body: (ScreenSharingHostOwnershipFixture) async throws -> Void) async throws {
    let fixture = ScreenSharingHostOwnershipFixture()
    try await fixture.open()
    do { try await body(fixture) } catch {
      await fixture.close()
      throw error
    }
    await fixture.close()
  }

  func send(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingReply {
    await host.handle(request)
  }

  func start(
    as app: ServerScreenSharingApp, _ intent: ServerScreenSharingRequest.Intent?, display: String? = "main"
  ) -> ServerScreenSharingRequest {
    var request = stableStart(display: display, mediaKey: app.key)
    request.app = app
    request.intent = intent
    return request
  }

  func stableStart(
    workspaceId: UUID = UUID(), paneId: UUID = UUID(), display: String? = "main",
    mediaKey: String = String(repeating: "f", count: 64)
  ) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .start, workspaceId: workspaceId, paneId: paneId, viewerId: UUID(), displayId: display)
    request.engine = "v2"
    request.media = .init(endpointId: mediaKey, relayUrl: nil, directAddrs: [])
    return request
  }

  func following(
    _ start: ServerScreenSharingRequest, _ operation: ServerScreenSharingRequest.Operation, viewerId: UUID? = nil
  ) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: operation, workspaceId: start.workspaceId, paneId: start.paneId,
      viewerId: viewerId ?? start.viewerId)
    request.app = start.app
    return request
  }

  private func open() async throws {
    let endpoint = try await netBindEndpoint(
      config: NetEndpointConfig(
        secretKeyHex: netGenerateSecretKeyHex(), relays: [], trustAnchorsPem: [], pathPolicy: "direct-only",
        alpns: [mediaAlpn()]))
    self.endpoint = endpoint
    media.configure { endpoint }
    host = ScreenSharingHostService(
      captureAccess: { [unowned self] in allowsCapture }, notificationCenter: NotificationCenter(),
      workspaceNotificationCenter: workspace,
      enumerateDisplays: { [unowned self] in
        try await (listDisplays?() ?? displays).map { (Self.displayID(of: $0), $0) }
      }, mediaEndpoint: media,
      displayChoice: .init(isHostVirtual: { $0 == Self.displayID(of: Self.hostVirtual) }))
  }

  private func close() async {
    await host.shutdown()
    await endpoint?.close()
  }

  nonisolated static func displayID(of display: ServerScreenSharingDisplay) -> CGDirectDisplayID {
    switch display.id {
    case "main": CGMainDisplayID()
    case "virtual": CGMainDisplayID() &+ 2
    default: CGMainDisplayID() &+ 1
    }
  }
}

extension ServerScreenSharingApp {
  static let macBook = ServerScreenSharingApp(key: String(repeating: "a", count: 64), name: "Alexandru's MacBook Pro")
  static let iPhone = ServerScreenSharingApp(key: String(repeating: "b", count: 64), name: "Alexandru's iPhone")
  static let iPad = ServerScreenSharingApp(key: String(repeating: "c", count: 64), name: "Alexandru's iPad")
}
