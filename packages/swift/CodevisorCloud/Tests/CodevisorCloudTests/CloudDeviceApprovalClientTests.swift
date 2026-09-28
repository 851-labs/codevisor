import Foundation
import Testing
@testable import CodevisorCloud

@Suite("Device approval requests")
struct CloudDeviceApprovalClientTests {
  private static let base = URL(string: "https://cloud.example")!

  /// A client that records each request and answers with the scripted
  /// status and body for its path.
  private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func append(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
  }

  private func client(
    claim: (Int, String) = (200, #"{"user_code":"ABCD-EFGH","status":"pending"}"#),
    decision: (Int, String) = (200, #"{"success":true}"#)
  ) -> (CloudAccountClient, Recorder) {
    let recorder = Recorder()
    let client = CloudAccountClient(baseURL: Self.base) { request in
      recorder.append(request)
      let url = try #require(request.url)
      let (status, body) = request.httpMethod == "GET" ? claim : decision
      return (
        Data(body.utf8),
        try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
      )
    }
    return (client, recorder)
  }

  @Test("Claims the code with the bearer token, then posts the decision", arguments: ["approve", "deny"])
  func claimsThenDecides(decision: String) async throws {
    let (client, recorder) = client()
    if decision == "approve" {
      try await client.approveDevice(userCode: "ABCD-EFGH", token: "session-token")
    } else {
      try await client.denyDevice(userCode: "ABCD-EFGH", token: "session-token")
    }
    let requests = recorder.requests
    try #require(requests.count == 2)
    let claim = requests[0]
    #expect(claim.httpMethod == "GET")
    #expect(claim.url?.absoluteString == "https://cloud.example/api/auth/device?user_code=ABCD-EFGH")
    #expect(claim.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
    let post = requests[1]
    #expect(post.httpMethod == "POST")
    #expect(post.url?.path == "/api/auth/device/\(decision)")
    #expect(post.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
    #expect(post.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try JSONDecoder().decode([String: String].self, from: #require(post.httpBody))
    #expect(body == ["userCode": "ABCD-EFGH"])
  }

  @Test("A code that is no longer pending is reported without posting a decision")
  func claimedCodeAlreadyProcessed() async throws {
    let (client, recorder) = client(claim: (200, #"{"user_code":"ABCD-EFGH","status":"approved"}"#))
    await #expect(throws: CloudDeviceApprovalError.alreadyProcessed) {
      try await client.approveDevice(userCode: "ABCD-EFGH", token: "t")
    }
    #expect(recorder.requests.count == 1)
  }

  @Test(
    "Device plugin errors map to actionable messages",
    arguments: [
      (
        400, #"{"error":"invalid_request","error_description":"Invalid user code"}"#,
        CloudDeviceApprovalError.invalidCode
      ),
      (400, #"{"error":"expired_token","error_description":"User code has expired"}"#, .expiredCode),
      (
        400, #"{"error":"invalid_request","error_description":"Device code already processed"}"#,
        .alreadyProcessed
      ),
      (403, #"{"error":"access_denied","error_description":"You are not authorized"}"#, .claimedByAnotherAccount),
    ])
  func mapsErrors(status: Int, body: String, expected: CloudDeviceApprovalError) async throws {
    let (claimFails, _) = client(claim: (status, body))
    await #expect(throws: expected) { try await claimFails.approveDevice(userCode: "ABCD-EFGH", token: "t") }
    let (decisionFails, _) = client(decision: (status, body))
    await #expect(throws: expected) { try await decisionFails.denyDevice(userCode: "ABCD-EFGH", token: "t") }
  }

  @Test("An expired session keeps the generic sign-in-expired error")
  func unauthorized() async throws {
    let (client, _) = client(decision: (401, #"{"error":"unauthorized"}"#))
    await #expect(throws: CloudAccountClientError.httpStatus(401)) {
      try await client.approveDevice(userCode: "ABCD-EFGH", token: "t")
    }
  }
}
