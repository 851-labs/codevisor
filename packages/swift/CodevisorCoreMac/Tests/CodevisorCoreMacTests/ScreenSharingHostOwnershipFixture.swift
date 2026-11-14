import CodevisorClient
import CodevisorNet
import CoreGraphics
import CryptoKit
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
  private var sessions: [UUID: String] = [:]
  private var latestSession: [String: String] = [:]

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
    let reply = await host.handle(await signed(request))
    if let session = reply.session {
      sessions[request.viewerId] = session
      if let app = request.app { latestSession[app.key] = session }
    }
    return reply
  }

  func heartbeat(as app: ServerScreenSharingApp) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .heartbeat, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    request.session = latestSession[app.key]
    return request
  }

  func challenge(for app: ServerScreenSharingApp = .macBook) async -> ServerScreenSharingChallenge? {
    var capabilities = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    capabilities.app = app
    return await host.handle(capabilities).challenge
  }

  func signed(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingRequest {
    guard let app = request.app, [.start, .restart].contains(request.operation), request.proof == nil,
      let challenge = await challenge(for: app)
    else { return request }

    var signed = request
    signed.proof = try? ServerScreenSharingProof(of: request, answering: challenge, signer: app.signer)
    return signed
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
    request.session = sessions[start.viewerId]
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
  static let macBook = ServerScreenSharingApp(key: signingKey(1).publicKey.rawRepresentation.hexEncoded, name: names[1])
  static let iPhone = ServerScreenSharingApp(key: signingKey(2).publicKey.rawRepresentation.hexEncoded, name: names[2])
  static let iPad = ServerScreenSharingApp(key: signingKey(3).publicKey.rawRepresentation.hexEncoded, name: names[3])

  var signer: ScreenSharingStartSigner {
    let key = Self.signingKey(UInt8(Self.names.firstIndex(of: name) ?? 0))
    return ScreenSharingStartSigner(key: self.key) { try key.signature(for: $0) }
  }

  private static let names = ["", "Alexandru's MacBook Pro", "Alexandru's iPhone", "Alexandru's iPad"]

  private static func signingKey(_ seed: UInt8) -> Curve25519.Signing.PrivateKey {
    (try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
      ?? Curve25519.Signing.PrivateKey()
  }
}
