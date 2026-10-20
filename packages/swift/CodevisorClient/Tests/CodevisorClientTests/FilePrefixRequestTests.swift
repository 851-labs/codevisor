import Foundation
import Testing

@testable import CodevisorClient

struct FilePrefixRequestTests {
  @Test("File previews ask for only the first bytes of a workspace file")
  func sessionFileRange() async throws {
    let transport = FilePrefixTransport(status: 206)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    let sessionId = UUID()
    let data = try await client.filePrefix(sessionId: sessionId, path: "Sources/App.swift", length: 1_024)
    let request = try #require(await transport.requests.first)
    #expect(data == Data("contents".utf8))
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-1023")
    #expect(request.url?.path == "/v1/fs/file")
    #expect(request.url?.query?.contains("sessionId=\(sessionId.uuidString)") == true)
  }

  @Test("Attachment previews ask for only the first bytes of the stored file")
  func attachmentRange() async throws {
    let transport = FilePrefixTransport(status: 206)
    let client = CodevisorServerClient(config: .init(requestTransport: transport))
    _ = try await client.filePrefix(id: "file-1", length: 10)
    let request = try #require(await transport.requests.first)
    #expect(request.value(forHTTPHeaderField: "Range") == "bytes=0-9")
    #expect(request.url?.path == "/v1/files/file-1")
  }

  @Test("An empty file reads as no bytes instead of failing its range")
  func emptyFile() async throws {
    let client = CodevisorServerClient(config: .init(requestTransport: FilePrefixTransport(status: 416)))
    #expect(try await client.filePrefix(id: "empty", length: 10).isEmpty)
  }
}

private actor FilePrefixTransport: ServerRequestTransport {
  let status: Int
  var requests: [URLRequest] = []

  init(status: Int) { self.status = status }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let body = status == 416 ? Data() : Data("contents".utf8)
    return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
  }
}
