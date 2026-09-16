import Foundation
import Testing

@testable import ScreenSharingRigKit

/// The socket boundary is the behavior under test here; the port is chosen by
/// the OS and every connection is closed by the server after one response.
struct RigHTTPServerTests {
  @Test func servesOneRequestPerConnectionOnLoopback() async throws {
    let server = try RigHTTPServer(port: 0, loopbackOnly: true) { request in
      guard RigHTTPCodec.isAuthorized(request, token: "0123456789abcdef") else { return .error(401, "no") }
      guard request.method == "POST", request.path == "/echo" else { return .error(404, "where") }
      return RigHTTPServer.Response(status: 200, body: request.body)
    }
    let port = try await server.start()
    defer { server.stop() }
    #expect(port > 0)
    let base = URL(string: "http://127.0.0.1:\(port)")!
    let (status, body) = try await RigHTTPClient.request(
      "POST", base.appendingPathComponent("echo"), token: "0123456789abcdef", body: Data("hello".utf8))
    #expect(status == 200)
    #expect(body == Data("hello".utf8))
    let (denied, deniedBody) = try await RigHTTPClient.request(
      "POST", base.appendingPathComponent("echo"), token: "wrong-token-value", body: Data())
    #expect(denied == 401)
    #expect(try RigJSON.decode(RigErrorBody.self, from: deniedBody).error == "no")
    let (missing, _) = try await RigHTTPClient.request(
      "GET", base.appendingPathComponent("nope"), token: "0123456789abcdef")
    #expect(missing == 404)
  }

  @Test func typedClientDecodesAndSurfacesServerErrors() async throws {
    let server = try RigHTTPServer(port: 0, loopbackOnly: true) { request in
      request.path == "/status"
        ? .json(200, RigErrorBody(error: "fine")) : .error(409, "busy")
    }
    let port = try await server.start()
    defer { server.stop() }
    let base = URL(string: "http://127.0.0.1:\(port)")!
    let ok = try await RigHTTPClient.get(
      base.appendingPathComponent("status"), token: "t", expecting: RigErrorBody.self)
    #expect(ok.error == "fine")
    await #expect(throws: RigHTTPClient.Failure.self) {
      try await RigHTTPClient.get(base.appendingPathComponent("other"), token: "t", expecting: RigErrorBody.self)
    }
  }
}
