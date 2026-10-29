import CodevisorClient
import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

@MainActor
@Suite("McpServerDraft")
struct McpServerDraftTests {
  private final class Recorder {
    var events: [String] = []
    var bodies: [UpdateMcpServerBody] = []
    var failure: Error?
  }

  private struct SaveFailed: LocalizedError {
    var errorDescription: String? { "The server rejected it." }
  }

  @Test("An invalid URL shows an inline error and saves nothing")
  func invalidURL() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp")
    draft.location = "mcp.example.com"

    await draft.commitLocation(using: actions(recorder, draft))

    #expect(draft.errors[.location] == "Enter an http or https URL.")
    #expect(recorder.bodies.isEmpty)
    #expect(draft.location == "mcp.example.com")
  }

  @Test("Moving to another host records consent for the new location before saving it")
  func newHostNeedsConsent() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp")
    draft.location = "https://other.example.org/mcp"
    #expect(draft.needsConsent)

    await draft.commitLocation(using: actions(recorder, draft))

    #expect(recorder.events == ["consent other.example.org", "save"])
    #expect(recorder.bodies == [UpdateMcpServerBody(url: "https://other.example.org/mcp")])
    #expect(draft.errors[.location] == nil)
  }

  @Test("A new path on the same host keeps the plugin's identity, so no consent is asked again")
  func samePublisherSkipsConsent() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp")
    draft.location = "https://mcp.example.com/v2/mcp"
    #expect(!draft.needsConsent)

    await draft.commitLocation(using: actions(recorder, draft))

    #expect(recorder.events == ["save"])
  }

  @Test("A command line splits into the program and its arguments")
  func commandParses() async throws {
    let (draft, recorder) = try make(command: "npx", args: ["-y", "old-server"])
    draft.location = "npx -y \"new server\" --port 4000"

    await draft.commitLocation(using: actions(recorder, draft))

    #expect(recorder.bodies == [UpdateMcpServerBody(command: "npx", args: ["-y", "new server", "--port", "4000"])])
  }

  @Test("Choosing a bearer token waits for the token, then saves both together")
  func bearerWaitsForToken() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp")

    await draft.selectAuthorization("bearer", using: actions(recorder, draft))
    #expect(recorder.bodies.isEmpty)
    #expect(draft.awaitsBearerToken)
    #expect(draft.errors[.bearerToken] == "Enter a token to use bearer authorization.")

    draft.bearerToken = "secret"
    await draft.commitBearerToken(using: actions(recorder, draft))

    #expect(recorder.bodies == [UpdateMcpServerBody(authType: "bearer", bearerToken: "secret")])
    #expect(draft.errors[.bearerToken] == nil)
    #expect(draft.bearerToken.isEmpty)
  }

  @Test("Header edits send only what changed; blank new rows are ignored and renames need a value")
  func secretChanges() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp", headers: ["X-Team", "X-Key"])
    draft.secrets.removeAll { $0.name == "X-Team" }
    draft.secrets.append(McpSecretEntry(name: "", value: "", existing: false))
    draft.secrets.append(McpSecretEntry(name: "X-Region", value: "eu", existing: false))

    await draft.commitSecrets(using: actions(recorder, draft))

    #expect(recorder.bodies == [UpdateMcpServerBody(headers: ["X-Region": "eu"], removeHeaders: ["X-Team"])])

    let (renamed, untouched) = try make(url: "https://mcp.example.com/mcp", headers: ["X-Key"])
    renamed.secrets[0].name = "X-Token"
    await renamed.commitSecrets(using: actions(untouched, renamed))

    #expect(renamed.errors[.secrets] == "Enter a value for each new entry.")
    #expect(untouched.bodies.isEmpty)
  }

  @Test("A failed save shows the server's message inline and keeps what was typed")
  func failureStaysInline() async throws {
    let (draft, recorder) = try make(url: "https://mcp.example.com/mcp")
    recorder.failure = SaveFailed()
    draft.location = "https://mcp.example.com/v2"

    await draft.commitLocation(using: actions(recorder, draft))

    #expect(draft.errors[.location] == "The server rejected it.")
    #expect(draft.location == "https://mcp.example.com/v2")
  }

  private func make(
    url: String? = nil, command: String? = nil, args: [String] = [], headers: [String] = []
  ) throws -> (McpServerDraft, Recorder) {
    var json: [String: Any] = [
      "id": "s1", "name": "Example", "kind": "managed", "transport": url == nil ? "stdio" : "http",
      "args": args, "enabled": true, "authType": "none", "connectionState": "connected",
      "toolCount": 0, "headerNames": headers, "environmentNames": [],
      "createdAt": "2026-10-28T00:00:00.000Z", "updatedAt": "2026-10-28T00:00:00.000Z",
    ]
    json["url"] = url
    json["command"] = command
    let server = try JSONDecoder().decode(ServerMcpServer.self, from: JSONSerialization.data(withJSONObject: json))
    return (McpServerDraft(server: server), Recorder())
  }

  private func actions(_ recorder: Recorder, _ draft: McpServerDraft) -> McpServerDraft.Actions {
    McpServerDraft.Actions(
      save: { body in
        recorder.events.append("save")
        if let failure = recorder.failure { throw failure }
        recorder.bodies.append(body)
        return Self.applying(body, to: draft.server)
      },
      recordConsent: { location in recorder.events.append("consent \(location.identity)") })
  }

  private static func applying(_ body: UpdateMcpServerBody, to server: ServerMcpServer) -> ServerMcpServer {
    var updated = server
    updated.url = body.url ?? server.url
    updated.command = body.command ?? server.command
    updated.args = body.args ?? server.args
    updated.authType = body.authType ?? server.authType
    let kept = (server.headerNames ?? []).filter { !(body.removeHeaders ?? []).contains($0) }
    updated.headerNames = kept + (body.headers.map { Array($0.keys) } ?? [])
    return updated
  }
}
