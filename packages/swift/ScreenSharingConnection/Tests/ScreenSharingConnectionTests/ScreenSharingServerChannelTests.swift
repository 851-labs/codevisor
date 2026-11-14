import CodevisorClient
import CodevisorTestSupport
import CryptoKit
import Foundation
import ScreenSharingConnection
import ScreenSharingV2
import Testing

@MainActor
@Suite("Screen share connection: over the real server channel", .timeLimit(.minutes(1)))
struct ScreenSharingServerChannelTests {
  private static let heartbeat = ScreenSharingConnectionDeadlines.heartbeatInterval

  @Test("The old-host pane is registered as a Codevisor machine-desktop pane of its workspace")
  func registersTheDesktopPane() async throws {
    let host = VerifyingHost()
    let channel = ScreenSharingServerChannel(client: CodevisorServerClient(config: .init(requestTransport: host)))
    let identity = ScreenSharingLegacyIdentity(workspaceId: UUID(), installId: UUID())

    try await channel.registerDesktopPane(identity)

    let request = try #require(await host.paneRequests.first)
    let pane = identity.paneId.uuidString.lowercased()
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect(request.url?.path == "/v1/workspaces/\(identity.workspaceId.uuidString.lowercased())/panes/\(pane)")
    #expect(body["id"] as? String == pane && body["paneType"] as? String == "machine-desktop")
    #expect(body["providerId"] as? String == "codevisor")
  }

  @Test("A host that verifies real signatures grants the start, and every new field crosses the HTTP channel")
  func speaksToANewHostOverHTTP() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let appKey = key.publicKey.rawRepresentation.hexEncoded
    let host = VerifyingHost()
    let channel = ScreenSharingServerChannel(client: CodevisorServerClient(config: .init(requestTransport: host)))
    let clock = TestClock()
    let media = FakeMedia()
    media.endpointId = appKey
    let manager = ScreenSharingConnectionManager(clock: ScreenSharingConnectionClock(clock))
    let machine = ScreenSharingMachine(
      id: "croissant", channel: { channel }, connector: media.connector, appName: "Alexandru's MacBook Pro",
      signer: ScreenSharingStartSigner(key: appKey) { try key.signature(for: $0) }, installId: UUID(),
      liveWorkspace: { nil })
    let connection = manager.connection(for: machine)
    let surface = connection.attach(.tab)
    surface.openedByUser()
    surface.setOnScreen(true)

    await awaitObserved { media.sessions.first?.tokens.count == 1 }
    await clock.waitForSleep(Self.heartbeat)
    media.sessions[0].host.deliverFrame(identity: 1)
    await awaitObserved { connection.state == .live }
    #expect(connection.display == VerifyingHost.display)

    clock.advance(by: Self.heartbeat)
    await host.answered.wait(for: 3)
    await clock.waitForSleep(Self.heartbeat, count: 2)
    await host.takeOver(by: "Alexandru's iPhone")
    clock.advance(by: Self.heartbeat)
    await awaitObserved { connection.state == .failed(.takenOver(by: "Alexandru's iPhone")) }
    await host.answered.wait(for: 5)

    let sent = await host.bodies
    #expect(sent.map { $0["operation"] as? String } == ["capabilities", "start", "heartbeat", "heartbeat", "stop"])
    let app = ["key": appKey, "name": "Alexandru's MacBook Pro"]
    #expect(sent[0]["app"] as? [String: String] == app && sent[1]["app"] as? [String: String] == app)
    #expect(sent[1]["intent"] as? String == "open")
    let proof = try #require(sent[1]["proof"] as? [String: String])
    #expect(proof["nonce"] == VerifyingHost.nonce && proof["signature"]?.count == 128)
    for request in sent[2...] {
      #expect(request["session"] as? String == VerifyingHost.session && request["app"] == nil)
    }
  }
}

private actor VerifyingHost: ServerRequestTransport {
  static let hostKey = String(repeating: "b", count: 64)
  static let nonce = String(repeating: "1", count: 64)
  static let session = String(repeating: "5", count: 64)
  static let display = ServerScreenSharingDisplay(
    id: "0A000000-0000-4000-8000-000000000001", name: "Built-in Display", width: 1920, height: 1080)

  nonisolated let answered = TestSignal()
  private(set) var bodies: [[String: any Sendable]] = []
  private(set) var paneRequests: [URLRequest] = []
  private var holder: String?

  func takeOver(by holder: String) {
    self.holder = holder
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard request.httpMethod == "POST" else {
      paneRequests.append(request)
      return (Data("{}".utf8), Self.response(to: request, status: 404))
    }

    let body = request.httpBody ?? Data()
    let json = try JSONSerialization.jsonObject(with: body) as? [String: any Sendable]
    bodies.append(json ?? [:])
    let reply = reply(to: try JSONDecoder().decode(ServerScreenSharingRequest.self, from: body))
    defer { answered.signal() }
    guard let reply else {
      return (
        Data(#"{"error":"Screen Sharing pane is no longer available"}"#.utf8), Self.response(to: request, status: 404)
      )
    }

    return (try JSONEncoder().encode(reply), Self.response(to: request, status: 200))
  }

  private func reply(to request: ServerScreenSharingRequest) -> ServerScreenSharingReply? {
    var reply: ServerScreenSharingReply
    switch request.operation {
    case .capabilities:
      reply = ServerScreenSharingReply(status: "available", displays: [Self.display])
      reply.engines = ["v2"]
      if request.app != nil { reply.challenge = .init(hostKey: Self.hostKey, nonce: Self.nonce) }
    case .start, .restart:
      guard request.proof?.nonce == Self.nonce, request.proof?.proves(request, to: Self.hostKey) == true else {
        reply = ServerScreenSharingReply(status: "failed")
        reply.reason = .proofRejected
        return reply
      }

      reply = ServerScreenSharingReply(status: "connecting", displays: [Self.display])
      reply.media = .init(endpointId: Self.hostKey, relayUrl: nil, directAddrs: [], token: "grant token")
      reply.session = Self.session
      reply.display = Self.display
    case .heartbeat:
      guard request.session == Self.session else { return nil }
      guard let holder else {
        reply = ServerScreenSharingReply(status: "viewing", displays: [Self.display])
        reply.display = Self.display
        break
      }

      reply = ServerScreenSharingReply(status: "failed", message: "Now viewing on \(holder).")
      reply.reason = .takenOver
      reply.holderName = holder
    case .stop, .setScale:
      reply = ServerScreenSharingReply(status: "stopped")
    }
    reply.abilities = [ServerScreenSharingReply.appSessions]
    return reply
  }

  private static func response(to request: URLRequest, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
  }
}
