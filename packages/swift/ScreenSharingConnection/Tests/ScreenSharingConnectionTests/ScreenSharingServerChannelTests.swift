import CodevisorClient
import Foundation
import ScreenSharingConnection
import Testing

@MainActor
@Suite("Screen share connection: server channel", .timeLimit(.minutes(1)))
struct ScreenSharingServerChannelTests {
  actor Recorder: ServerRequestTransport {
    private(set) var requests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      requests.append(request)
      let isPane = request.httpMethod == "PUT"
      let body = isPane ? Data("{}".utf8) : try JSONEncoder().encode(ServerScreenSharingReply(status: "viewing"))
      let status = isPane ? 404 : 200
      return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
  }

  @Test("The old-host pane is registered as a Codevisor machine-desktop pane of its workspace")
  func registersTheDesktopPane() async throws {
    let recorder = Recorder()
    let channel = ScreenSharingServerChannel(client: CodevisorServerClient(config: .init(requestTransport: recorder)))
    let identity = ScreenSharingLegacyIdentity(workspaceId: UUID(), installId: UUID())

    try await channel.registerDesktopPane(identity)

    let request = try #require(await recorder.requests.first)
    let pane = identity.paneId.uuidString.lowercased()
    let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/v1/workspaces/\(identity.workspaceId.uuidString.lowercased())/panes/\(pane)")
    #expect(body["id"] as? String == pane && body["paneType"] as? String == "machine-desktop")
    #expect(body["providerId"] as? String == "codevisor")
  }

  @Test("A host request is posted to the screen sharing route and its reply handed back")
  func postsHostRequests() async throws {
    let recorder = Recorder()
    let channel = ScreenSharingServerChannel(client: CodevisorServerClient(config: .init(requestTransport: recorder)))
    let base = ServerScreenSharingRequest(operation: .heartbeat, workspaceId: UUID(), paneId: UUID(), viewerId: UUID())

    let reply = try await channel.send(ScreenSharingHostRequest(base))

    let request = try #require(await recorder.requests.first)
    let sent = try JSONDecoder().decode(ServerScreenSharingRequest.self, from: request.httpBody ?? Data())
    #expect(request.url?.path == "/v1/screen-sharing" && sent.viewerId == base.viewerId)
    #expect(reply.base.status == "viewing" && reply.abilities.isEmpty)
  }
}
