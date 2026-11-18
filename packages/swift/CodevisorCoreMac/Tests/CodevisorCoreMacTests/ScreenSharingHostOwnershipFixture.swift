import CodevisorClient
import CodevisorNet
import CoreGraphics
import CryptoKit
import Foundation
import ScreenSharing
import ScreenSharingV2

@testable import CodevisorCoreMac

@MainActor
final class ScreenSharingHostOwnershipFixture {
  nonisolated static let main = ServerScreenSharingDisplay(
    id: "main", name: "Built-in Display", width: 1280, height: 720)
  nonisolated static let side = ServerScreenSharingDisplay(id: "side", name: "Side Display", width: 1280, height: 720)
  nonisolated static let hostVirtual = ServerScreenSharingDisplay(
    id: "virtual", name: "Codevisor Screen Sharing", width: 3840, height: 2160)
  nonisolated static let standIn = ServerScreenSharingDisplay(
    id: "stand-in", name: "Display", width: 1920, height: 1080)
  nonisolated static let standInAgain = ServerScreenSharingDisplay(
    id: "stand-in-again", name: "Display", width: 1920, height: 1080)

  var displays = [ScreenSharingHostOwnershipFixture.main]
  var listDisplays: (() async throws -> [ServerScreenSharingDisplay])?
  var allowsCapture = true
  var failsCaptureOn: Set<String> = []
  var captureFailure: any Error = ScreenSharingError.unavailable("Capture refused.")
  private(set) var captureStarts: [String] = []
  let workspace = NotificationCenter()
  let media = ScreenSharingMediaEndpoint()
  let hosting = ScreenSharingHostActivityLog()
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

  func heartbeat(as app: ServerScreenSharingApp, sharing display: String? = nil) -> ServerScreenSharingRequest {
    var request = ServerScreenSharingRequest(
      operation: .heartbeat, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: display)
    request.session = latestSession[app.key]
    return request
  }

  func capabilities(as app: ServerScreenSharingApp?) async -> ServerScreenSharingReply {
    var request = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    request.app = app
    return await host.handle(request)
  }

  func show(_ displays: [ServerScreenSharingDisplay], sharedAs display: ServerScreenSharingDisplay) async throws {
    self.displays = displays
    guard let session = host.current else { return }

    session.displayID = Self.displayID(of: display)
    await host.refreshDisplays(of: session)
  }

  func challenge(for app: ServerScreenSharingApp = .macBook) async -> ServerScreenSharingChallenge? {
    var capabilities = ServerScreenSharingRequest(
      operation: .capabilities, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())
    capabilities.app = app
    return await host.handle(capabilities).challenge
  }

  func signed(_ request: ServerScreenSharingRequest) async -> ServerScreenSharingRequest {
    guard let app = request.app, request.operation == .start, request.proof == nil,
      let challenge = await challenge(for: app)
    else { return request }

    var signed = request
    signed.proof = try? ServerScreenSharingProof(of: request, answering: challenge, signer: app.signer)
    return signed
  }

  func start(
    as app: ServerScreenSharingApp, _ intent: ServerScreenSharingRequest.Intent?, display: String? = "main"
  ) -> ServerScreenSharingRequest {
    var request = startWithoutApp(display: display, mediaKey: app.key)
    request.app = app
    request.intent = intent
    return request
  }

  func startWithoutApp(
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
      logicalDisplays: .init(kind: Self.kind), activity: hosting.activity)
    host.onlineDisplays = { [unowned self] in displays.map(Self.online) }
    host.virtualDisplaysAvailable = { false }
    host.isMirrored = { _ in false }
    host.startsCapture = { [unowned self] session in
      let display = displays.first { Self.displayID(of: $0) == session.captureDisplayID }?.id ?? "unknown"
      captureStarts.append(display)
      guard !failsCaptureOn.contains(display) else { throw captureFailure }
    }
  }

  nonisolated private static func online(_ display: ServerScreenSharingDisplay) -> ScreenSharingDisplayIdentity.Online {
    let id = displayID(of: display)
    return .init(
      id: id, identity: .init(vendor: 1, model: 1, serial: id), isMain: id == CGMainDisplayID(),
      isVirtual: kind(of: id) == .hostVirtual, pixels: .init(width: display.width, height: display.height))
  }

  private func close() async {
    await host.shutdown()
    await endpoint?.close()
  }

  nonisolated static func displayID(of display: ServerScreenSharingDisplay) -> CGDirectDisplayID {
    switch display.id {
    case "main": CGMainDisplayID()
    case "virtual": CGMainDisplayID() &+ 2
    case "stand-in": CGMainDisplayID() &+ 3
    case "stand-in-again": CGMainDisplayID() &+ 4
    case "other": CGMainDisplayID() &+ 5
    default: CGMainDisplayID() &+ 1
    }
  }

  nonisolated static func kind(of display: CGDirectDisplayID) -> ScreenSharingHostLogicalDisplays.Kind {
    switch display {
    case displayID(of: hostVirtual): .hostVirtual
    case displayID(of: standIn), displayID(of: standInAgain): .standIn
    default: .real
    }
  }
}

extension ServerScreenSharingApp {
  static let macBook = ServerScreenSharingApp(key: signingKey(1).publicKey.rawRepresentation.hexEncoded, name: names[1])
  static let iPhone = ServerScreenSharingApp(key: signingKey(2).publicKey.rawRepresentation.hexEncoded, name: names[2])
  static let iPad = ServerScreenSharingApp(key: signingKey(3).publicKey.rawRepresentation.hexEncoded, name: names[3])

  static func viewer(_ number: Int) -> ServerScreenSharingApp {
    ServerScreenSharingApp(
      key: signingKey(seed(of: "Viewer \(number)")).publicKey.rawRepresentation.hexEncoded, name: "Viewer \(number)")
  }

  var signer: ScreenSharingStartSigner {
    let key = Self.signingKey(Self.seed(of: name))
    return ScreenSharingStartSigner(key: self.key) { try key.signature(for: $0) }
  }

  private static func seed(of name: String) -> UInt8 {
    if let index = names.firstIndex(of: name) { return UInt8(index) }
    return UInt8(10 + (Int(name.dropFirst("Viewer ".count)) ?? 0))
  }

  private static let names = ["", "Alexandru's MacBook Pro", "Alexandru's iPhone", "Alexandru's iPad"]

  private static func signingKey(_ seed: UInt8) -> Curve25519.Signing.PrivateKey {
    (try? Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)))
      ?? Curve25519.Signing.PrivateKey()
  }
}
