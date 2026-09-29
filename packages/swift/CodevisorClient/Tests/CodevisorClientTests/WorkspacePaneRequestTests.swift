import ACPKit
import Foundation
import Testing

@testable import CodevisorClient

struct WorkspacePaneRequestTests {
  static let workspaceId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  static let paneId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

  @Test("A pane upsert never sends the server-owned title or terminal status")
  func upsertOmitsServerOwnedFields() async throws {
    let transport = PaneTransport()
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let pane = ServerWorkspacePane(
      id: Self.paneId.uuidString, workspaceId: Self.workspaceId.uuidString, providerId: "codevisor",
      paneType: "terminal", title: "Terminal 1", resourceKind: "terminal", resourceId: "t1",
      createdAt: "2026-01-01T00:00:00.000Z", liveTitle: "Claude Code", terminalActivity: "working")
    _ = try await client.upsertWorkspacePane(pane)

    let request = try #require(await transport.requests.first)
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body["title"] == .string("Terminal 1"))
    #expect(body["liveTitle"] == nil)
    #expect(body["terminalActivity"] == nil)
  }
}

/// Answers every request with 200, echoing a pane upsert's record.
private actor PaneTransport: ServerRequestTransport {
  var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    var body = Data()
    if request.httpMethod == "PUT", let sent = request.httpBody,
      var record = try JSONSerialization.jsonObject(with: sent) as? [String: Any]
    {
      record["workspaceId"] = WorkspacePaneRequestTests.workspaceId.uuidString
      body = try JSONSerialization.data(withJSONObject: record)
    }
    return (
      body,
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
