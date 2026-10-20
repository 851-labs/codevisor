import Foundation
import Testing

@testable import CodevisorClient

struct WorkspaceMediaRequestTests {
  static let workspaceId = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
  static let sessionId = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!

  static func item(_ name: String, mimeType: String, extra: String = "") -> String {
    """
    {"attachment":{"fileId":"\(name)","name":"\(name)","mimeType":"\(mimeType)","sizeBytes":9,
     "kind":"file"},"sessionId":"\(sessionId)","itemId":"item","createdAt":"2026-10-15T12:00:00Z",
     "source":"tool"\(extra)}
    """
  }

  @Test("Media pages carry videos with their durations")
  func mediaPage() async throws {
    let transport = MediaTransport(responses: [
      "/media": (
        200,
        """
        {"media":[\(Self.item("clip.mov", mimeType: "video/quicktime", extra: #","durationSeconds":4.25"#)),
        \(Self.item("shot.png", mimeType: "image/png"))],"nextBefore":"cursor"}
        """
      )
    ])
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let page = try await client.workspaceMedia(workspaceId: Self.workspaceId, before: "older", limit: 60)
    #expect(page.media.map(\.isVideo) == [true, false])
    #expect(page.media.map(\.durationSeconds) == [4.25, nil])
    #expect(page.nextBefore == "cursor")
    let request = try #require(await transport.requests.first)
    #expect(request.url?.path == "/v1/workspaces/\(Self.workspaceId.uuidString)/media")
    #expect(request.url?.query == "limit=60&before=older")
  }

  @Test("An older server without the media route still lists its images")
  func photosFallback() async throws {
    let transport = MediaTransport(responses: [
      "/media": (404, #"{"error":"Not found"}"#),
      "/photos": (200, #"{"photos":[\#(Self.item("shot.png", mimeType: "image/png"))],"nextBefore":"next"}"#),
    ])
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let page = try await client.workspaceMedia(workspaceId: Self.workspaceId, before: "older", limit: 60)
    #expect(page.media.map(\.attachment.name) == ["shot.png"])
    #expect(page.nextBefore == "next")
    let paths = await transport.requests.compactMap { $0.url?.path.split(separator: "/").last }
    #expect(paths == ["media", "photos"])
    #expect(await transport.requests.last?.url?.query == "limit=60&before=older")
  }
}

private actor MediaTransport: ServerRequestTransport {
  let responses: [String: (Int, String)]
  var requests: [URLRequest] = []

  init(responses: [String: (Int, String)]) { self.responses = responses }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let path = request.url!.path
    let (status, body) = responses.first { path.hasSuffix($0.key) }?.value ?? (404, "{}")
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    )
  }
}
