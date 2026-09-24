import Foundation
import Testing

@testable import ScreenSharingRigKit

/// The rig's own Screen Sharing pane on a Codevisor server (851-2384).
struct RigServerPaneTests {
  final class Recorder: @unchecked Sendable {
    let lock = NSLock()
    var requests: [URLRequest] = []
    var status: (URLRequest) -> Int = { _ in 200 }
  }

  static func send(_ recorder: Recorder) -> @Sendable (URLRequest) async throws -> (Data, URLResponse) {
    { request in
      let status = recorder.lock.withLock {
        recorder.requests.append(request)
        return recorder.status(request)
      }
      return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
  }

  @Test func createsTheProjectWorkspaceAndPaneInOrderWithValidJSON() async throws {
    let recorder = Recorder()
    try await RigServerPane.ensure(
      baseURL: URL(string: "http://mac.local:49361")!, token: "t0k", send: Self.send(recorder))
    let requests = recorder.requests
    #expect(
      requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
        "POST /v1/projects/scratch",
        "PUT /v1/workspaces/\(RigServerPane.workspaceId.uuidString)",
        "PUT /v1/workspaces/\(RigServerPane.workspaceId.uuidString)/panes/\(RigServerPane.paneId.uuidString)",
      ])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0k" })
    let pane = try #require(
      JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
    #expect(pane["paneType"] as? String == "screen-sharing" && pane["providerId"] as? String == "codevisor")
    let metadata = try JSONSerialization.jsonObject(with: Data((pane["metadata"] as! String).utf8)) as? [String: Int]
    #expect(metadata == ["schemaVersion": 1], "the app's ScreenSharingPanePreferences")
    let workspace = try #require(
      JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
    #expect(workspace["projectId"] as? String == RigServerPane.projectId.uuidString)
    #expect(workspace["hasCustomName"] as? Bool == true)
  }

  @Test func aRefusedStepStopsWithItsStatus() async {
    let recorder = Recorder()
    recorder.status = { $0.httpMethod == "PUT" ? 404 : 201 }
    await #expect(throws: RigServerPane.Failure.self) {
      try await RigServerPane.ensure(baseURL: URL(string: "http://m")!, token: "t", send: Self.send(recorder))
    }
    #expect(recorder.requests.count == 2)
  }
}
