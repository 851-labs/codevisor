import Foundation
import Testing

@testable import ScreenSharingRigKit

struct RigHTTPTests {
  @Test func parsesPostWithBodyAndReportsConsumedBytes() {
    let body = #"{"a":1}"#
    let raw =
      "POST /offer HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer t\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    guard case .complete(let request, let consumed) = RigHTTPCodec.parse(Data(raw.utf8)) else {
      Issue.record("expected a complete request")
      return
    }
    #expect(request.method == "POST")
    #expect(request.path == "/offer")
    #expect(request.headers["authorization"] == "Bearer t")
    #expect(request.headers["host"] == "x")
    #expect(request.body == Data(body.utf8))
    #expect(consumed == raw.utf8.count)
  }

  @Test func partialInputIsIncompleteUntilBodyArrives() {
    let head = "POST /x HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
    #expect(RigHTTPCodec.parse(Data("POST /x HTTP/1.1\r\nContent-Le".utf8)) == .incomplete)
    #expect(RigHTTPCodec.parse(Data((head + "ab").utf8)) == .incomplete)
    guard case .complete(let request, _) = RigHTTPCodec.parse(Data((head + "abcde").utf8)) else {
      Issue.record("expected completion once the body is present")
      return
    }
    #expect(request.body == Data("abcde".utf8))
  }

  @Test func getWithoutContentLengthHasEmptyBody() {
    guard case .complete(let request, let consumed) = RigHTTPCodec.parse(Data("GET /status HTTP/1.1\r\n\r\n".utf8))
    else {
      Issue.record("expected a complete request")
      return
    }
    #expect(request.body.isEmpty)
    #expect(consumed == "GET /status HTTP/1.1\r\n\r\n".utf8.count)
  }

  @Test(arguments: [
    "get /x HTTP/1.1\r\n\r\n", "GET x HTTP/1.1\r\n\r\n", "GET /x HTTP/2\r\n\r\n", "GET /x\r\n\r\n",
    "GET /x HTTP/1.1\r\nbroken header\r\n\r\n", "GET /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
    "GET /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n", "GET /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
    "GET /x HTTP/1.1\r\nContent-Length: 600000\r\n\r\n",
  ])
  func malformedRequestsAreInvalid(_ raw: String) {
    guard case .invalid = RigHTTPCodec.parse(Data(raw.utf8)) else {
      Issue.record("expected invalid for \(raw.debugDescription)")
      return
    }
  }

  @Test func oversizedHeadersFailBeforeTheTerminatorArrives() {
    let huge = "GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: RigHTTPCodec.maximumHeaderBytes + 1)
    guard case .invalid = RigHTTPCodec.parse(Data(huge.utf8)) else {
      Issue.record("expected oversized headers to be rejected")
      return
    }
  }

  @Test func responsesCarryLengthAndNoStore() {
    let response = String(decoding: RigHTTPCodec.response(status: 404, body: Data("{}".utf8)), as: UTF8.self)
    #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    #expect(response.contains("Content-Length: 2\r\n"))
    #expect(response.contains("Cache-Control: no-store\r\n"))
    #expect(response.contains("Connection: close\r\n\r\n{}"))
  }

  @Test func bearerAuthorizationIsExactAndRequired() {
    func request(_ header: String?) -> RigHTTPRequest {
      RigHTTPRequest(method: "GET", path: "/", headers: header.map { ["authorization": $0] } ?? [:], body: Data())
    }
    #expect(RigHTTPCodec.isAuthorized(request("Bearer secret-token-value"), token: "secret-token-value"))
    #expect(!RigHTTPCodec.isAuthorized(request("Bearer secret-token-valu"), token: "secret-token-value"))
    #expect(!RigHTTPCodec.isAuthorized(request("Bearer secret-token-valueX"), token: "secret-token-value"))
    #expect(!RigHTTPCodec.isAuthorized(request("Basic secret-token-value"), token: "secret-token-value"))
    #expect(!RigHTTPCodec.isAuthorized(request(nil), token: "secret-token-value"))
    #expect(!RigHTTPCodec.isAuthorized(request("Bearer "), token: ""))
  }
}
