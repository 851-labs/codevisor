import ACPKit
import Foundation
import Testing

@testable import CodevisorClient

struct PromptRequestTests {
  @Test("Prompts carry the sending window's client-control id for the server's turn origin")
  func promptNamesItsWindow() async throws {
    let transport = PromptTransport()
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let id = UUID()
    _ = try await client.promptSession(
      id: id, text: "Ship it", attachments: [], messageId: "message-1", clientId: "window-1"
    )
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/v1/sessions/\(id.uuidString)/prompt")
    let body = try JSONDecoder().decode([String: JSONValue].self, from: #require(request.httpBody))
    #expect(body["clientId"] == .string("window-1"))
    #expect(body["messageId"] == .string("message-1"))
  }
}

private actor PromptTransport: ServerRequestTransport {
  var requests: [URLRequest] = []

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    return (
      Data(#"{"accepted":true,"sessionId":"session"}"#.utf8),
      HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
