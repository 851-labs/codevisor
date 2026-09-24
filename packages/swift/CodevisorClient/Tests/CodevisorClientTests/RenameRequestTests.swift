import ACPKit
import CodevisorProtocol
import Foundation
import Testing

@testable import CodevisorClient

struct RenameRequestTests {
  @Test("Workspace renames send only name metadata to the owning server")
  func workspacePatch() async throws {
    let transport = RenameTransport(sessionExists: true)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let id = UUID()
    try await client.renameWorkspace(id: id, name: "Shared name", hasCustomName: true)
    let requests = await transport.requests
    #expect(requests.count == 1)
    let request = try #require(requests.first)
    #expect(request.httpMethod == "PATCH")
    #expect(request.url?.path == "/v1/workspaces/\(id.uuidString)")
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body == ["name": .string("Shared name"), "hasCustomName": .bool(true)])
  }

  @Test("Chat renames avoid unrelated updates and create missing drafts", arguments: [false, true])
  func chatPatch(sessionExists: Bool) async throws {
    let transport = RenameTransport(sessionExists: sessionExists)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let chat = ChatSession(id: RenameTransport.sessionId, projectId: RenameTransport.projectId, title: "Shared title")
    _ = try await client.renameSession(chat)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == (sessionExists ? ["GET", "PATCH"] : ["GET", "POST", "PATCH"]))
    let request = try #require(requests.last)
    #expect(request.url?.path == "/v1/sessions/\(chat.id.uuidString)")
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body == ["title": .string("Shared title"), "titleIntent": .string("rename")])
  }
}

private actor RenameTransport: ServerRequestTransport {
  static let sessionId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  static let projectId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  let sessionExists: Bool
  var requests: [URLRequest] = []

  init(sessionExists: Bool) { self.sessionExists = sessionExists }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let record = """
      {"id":"\(Self.sessionId)","projectId":"\(Self.projectId)","serverId":"local",
       "title":"Shared title","harnessId":"codex","origin":"codevisor",
       "createdAt":"2026-06-30T00:00:00Z"}
      """
    let body = request.httpMethod == "GET" ? (sessionExists ? "[\(record)]" : "[]") : record
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
