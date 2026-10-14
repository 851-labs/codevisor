import Foundation

public enum RigServerPane {
  public static let projectId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F01")!
  public static let workspaceId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F02")!
  public static let paneId = UUID(uuidString: "5C2E1A7B-0D3F-4B8E-9A61-7E4C2B1D9F03")!

  public struct Request: Equatable, Sendable {
    public var method: String
    public var path: String
    public var body: String
  }

  public static let requests: [Request] = [
    Request(method: "POST", path: "/v1/projects/scratch", body: #"{"id":"\#(projectId.uuidString)"}"#),
    Request(
      method: "PUT", path: "/v1/workspaces/\(workspaceId.uuidString)",
      body:
        #"{"hasCustomName":true,"id":"\#(workspaceId.uuidString)","name":"Screen Sharing Rig","projectId":"\#(projectId.uuidString)"}"#
    ),
    Request(
      method: "PUT", path: "/v1/workspaces/\(workspaceId.uuidString)/panes/\(paneId.uuidString)",
      body:
        #"{"id":"\#(paneId.uuidString)","metadata":"{\"schemaVersion\":1}","paneType":"screen-sharing","providerId":"codevisor","title":"Screen Sharing Rig"}"#
    ),
  ]

  public struct Failure: LocalizedError, Equatable {
    public let errorDescription: String?
  }

  public static func ensure(
    baseURL: URL, token: String,
    send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
  ) async throws {
    for step in requests {
      var request = URLRequest(url: baseURL.appending(path: step.path))
      request.httpMethod = step.method
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = Data(step.body.utf8)
      let (_, response) = try await send(request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard (200..<300).contains(status) else {
        throw Failure(
          errorDescription: "The server refused the rig's Screen Sharing pane (\(step.method) \(step.path): \(status))."
        )
      }
    }
  }
}
